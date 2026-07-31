import Foundation

/// Runs blocking work off the cooperative pool.
///
/// Swift's concurrency runtime keeps roughly one thread per core and expects
/// tasks to suspend rather than block. Walking a home directory or sizing a
/// browser cache does neither, it sits in `stat` for seconds, and a
/// `Task.detached` doing that parks one of those few threads, starving
/// everything else that wants to run. A dispatch queue is the right tool for
/// work that genuinely blocks, so this bridges the two worlds in one place
/// instead of scattering the reasoning across every scanner.
enum BackgroundWork {
    private static let queue = DispatchQueue(label: "com.snapdesk.background",
                                             qos: .userInitiated, attributes: .concurrent)

    static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
