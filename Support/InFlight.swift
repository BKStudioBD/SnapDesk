import Foundation

/// A "one at a time" latch that cannot kill a shortcut permanently.
///
/// Every capture feature guards itself with a flag so a held-down hotkey can't
/// start five overlapping captures. The flag was a plain `Bool` cleared by a
/// `defer` inside the task doing the work, which is correct only while that task
/// always finishes. `SCScreenshotManager.captureImage` can hang: when it does,
/// the task never exits, the flag is never cleared, and the shortcut is dead for
/// the rest of the app's life. Nothing is written anywhere, because the failure
/// is upstream of everything that logs. That is what "it stops working
/// sometimes" was.
///
/// So the latch remembers WHEN it was taken. A press that arrives while a fresh
/// one is held is still refused, and a press that arrives after a hold has
/// outlasted anything the work could legitimately take takes it over. The
/// deadline on the work itself is the real fix; this is the guarantee that one
/// escaped case cannot cost the user the feature until they restart.
struct InFlightLatch {

    /// How long a hold can last before a new attempt is allowed to take over.
    /// Generous on purpose: refusing a second press is a small annoyance,
    /// stealing the latch from work that IS still running is a real bug.
    let timeout: TimeInterval

    private var takenAt: Date?

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// True when the caller now owns the latch and should proceed.
    ///
    /// - Returns: false only while a hold is still within `timeout`.
    mutating func take(now: Date = Date()) -> Bool {
        if let takenAt, now.timeIntervalSince(takenAt) < timeout { return false }
        takenAt = now
        return true
    }

    mutating func release() { takenAt = nil }

    /// Whether a press right now would be refused. For tests and diagnostics.
    func isHeld(now: Date = Date()) -> Bool {
        guard let takenAt else { return false }
        return now.timeIntervalSince(takenAt) < timeout
    }

    /// True when a hold was abandoned rather than released: the work outlasted
    /// its own deadline and never came back.
    func isStale(now: Date = Date()) -> Bool {
        guard let takenAt else { return false }
        return now.timeIntervalSince(takenAt) >= timeout
    }
}

/// Runs `operation`, giving up on WAITING for it after `seconds`.
///
/// The underlying call is not necessarily cancellable: ScreenCaptureKit may
/// still be off doing whatever wedged it. What this guarantees is that the
/// CALLER stops waiting, so the latch above is released, the error reaches the
/// user, and the next press gets a fresh attempt.
///
/// Deliberately NOT a task group. A group awaits every child before its body
/// can return, so cancelling the loser only helps when the loser cooperates. A
/// call blocked inside a C API does not, and the group would sit there waiting
/// for exactly the thing whose hanging this exists to survive. Unstructured
/// tasks and a first-past-the-post resume are what make the timeout real. The
/// stuck task is left to finish into a result nobody reads, which is the honest
/// price of a system call that cannot be cancelled.
func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
        once.arm(continuation)
        Task {
            do { once.finish(.success(try await operation())) }
            catch { once.finish(.failure(error)) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            once.finish(.failure(DeadlineError.timedOut(after: seconds)))
        }
    }
}

/// Resumes a continuation exactly once, whichever racer gets there first.
/// Resuming twice is undefined behaviour, and both racers here are expected to
/// finish eventually.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func arm(_ c: CheckedContinuation<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        continuation = c
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

enum DeadlineError: LocalizedError {
    case timedOut(after: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            "The screen didn't respond within \(Int(seconds)) seconds. Try again."
        }
    }
}
