import Testing
import Foundation
@testable import SnapDeskCore

/// The guarantee that a shortcut cannot die permanently.
///
/// The old flag was a `Bool` cleared by a `defer` inside the task doing the
/// work. When `SCScreenshotManager.captureImage` hung, that task never exited,
/// the flag was never cleared, and the shortcut was dead until the app was
/// restarted, with nothing written anywhere because the hang is upstream of
/// every log.
struct InFlightTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("A free latch is taken")
    func takesWhenFree() {
        var latch = InFlightLatch(timeout: 60)
        let took = latch.take(now: start)
        #expect(took)
    }

    @Test("A second press during real work is refused")
    func refusesWhileHeld() {
        var latch = InFlightLatch(timeout: 60)
        let first = latch.take(now: start)
        let second = latch.take(now: start.addingTimeInterval(5))
        #expect(first)
        #expect(second == false)
        #expect(latch.isHeld(now: start.addingTimeInterval(5)))
    }

    @Test("Releasing frees it immediately")
    func releaseFrees() {
        var latch = InFlightLatch(timeout: 60)
        _ = latch.take(now: start)
        latch.release()
        let retaken = latch.take(now: start.addingTimeInterval(1))
        latch.release()
        #expect(retaken)
        #expect(latch.isHeld(now: start.addingTimeInterval(1)) == false)
    }

    @Test("An abandoned hold is taken over instead of blocking forever")
    func staleHoldIsRecovered() {
        var latch = InFlightLatch(timeout: 60)
        _ = latch.take(now: start)
        // The work hung and never released. Before this, every press from here
        // to the end of the app's life returned early.
        let later = start.addingTimeInterval(61)
        let stale = latch.isStale(now: later)
        let recovered = latch.take(now: later)
        #expect(stale)
        #expect(recovered)
    }

    @Test("Taking over restarts the clock, so the new work gets its full window")
    func takeoverResetsTheClock() {
        var latch = InFlightLatch(timeout: 60)
        _ = latch.take(now: start)
        let takeover = start.addingTimeInterval(61)
        let tookOver = latch.take(now: takeover)
        let refused = latch.take(now: takeover.addingTimeInterval(5))
        #expect(tookOver)
        #expect(refused == false)
    }

    @Test("A fresh latch is neither held nor stale")
    func freshLatchIsQuiet() {
        let latch = InFlightLatch(timeout: 60)
        #expect(latch.isHeld(now: start) == false)
        #expect(latch.isStale(now: start) == false)
    }

    @Test("Work that beats the deadline returns its value")
    func deadlinePassesThroughSuccess() async throws {
        let value = try await withDeadline(5) { 42 }
        #expect(value == 42)
    }

    @Test("Work that outlasts the deadline throws instead of waiting forever")
    func deadlineFiresOnAHang() async {
        await #expect(throws: DeadlineError.self) {
            try await withDeadline(0.05) {
                // Stands in for a ScreenCaptureKit call that never comes back.
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 0
            }
        }
    }

    @Test("The timeout message tells the user what to do")
    func deadlineErrorReads() {
        let text = DeadlineError.timedOut(after: 10).errorDescription ?? ""
        #expect(text.contains("10"))
        #expect(text.contains("Try again"))
    }
}
