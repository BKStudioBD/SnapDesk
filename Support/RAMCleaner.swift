import Foundation
import os

/// Frees inactive memory by asking the kernel for it.
///
/// macOS keeps "free" memory near zero on purpose — everything spare is cache —
/// so the target here is RECLAIMABLE pages: inactive, purgeable, speculative and
/// free. Claiming that much and immediately handing it back makes the pager
/// evict the cache, and the counters stay up afterwards.
///
/// The allocation uses `vm_allocate`/`vm_deallocate` rather than `malloc`/`free`
/// because malloc keeps freed pages in its own arena: the process looks smaller
/// but the kernel never gets the memory back, which is the entire point.
enum RAMCleaner {

    /// One run at a time. A second press while a pass is in flight would fight
    /// the first for the same pages and report nonsense.
    private static let isRunning = OSAllocatedUnfairLock(initialState: false)

    /// Long-running, deliberately blocking work — a tight `memset` over
    /// gigabytes. It gets its own queue instead of a `Task`: parking that on
    /// Swift's cooperative pool would hold a thread the rest of the app needs.
    private static let queue = DispatchQueue(label: "com.snapdesk.ramcleaner", qos: .utility)

    // MARK: - Reading

    private static func stats() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                let host = mach_host_self()
                defer { mach_port_deallocate(mach_task_self_, host) }
                return host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    /// Free physical memory right now.
    static func freeBytes() -> UInt64 {
        guard let stats = stats() else { return 0 }
        return (UInt64(stats.free_count) + UInt64(stats.speculative_count))
             * UInt64(vm_kernel_page_size)
    }

    /// What the kernel could hand back under pressure.
    static func reclaimableBytes() -> UInt64 {
        guard let stats = stats() else { return 0 }
        let pages = UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
                  + UInt64(stats.speculative_count) + UInt64(stats.free_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    // MARK: - Cleaning

    /// Run a pass. Returns free memory before and after.
    static func clean() async -> (before: UInt64, after: UInt64) {
        let alreadyRunning = isRunning.withLock { running -> Bool in
            if running { return true }
            running = true
            return false
        }
        guard !alreadyRunning else {
            let now = freeBytes()
            return (now, now)
        }
        defer { isRunning.withLock { $0 = false } }

        let before = freeBytes()
        let after = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: pressurePass()) }
        }
        return (before, after)
    }

    /// The blocking part. Never call this on the main thread.
    private static func pressurePass() -> UInt64 {
        // The real thing first, if this Mac allows it. It fails silently under
        // the sandbox and on machines without developer tools, which is fine —
        // the allocation pass below does the same job the slow way.
        let purge = Process()
        purge.executableURL = URL(fileURLWithPath: "/usr/sbin/purge")
        purge.standardOutput = nil
        purge.standardError = nil
        if (try? purge.run()) != nil { purge.waitUntilExit() }

        // Back off the instant the system reports pressure. A memory cleaner
        // that causes a system-wide stall has done the opposite of its job.
        let underPressure = OSAllocatedUnfairLock(initialState: false)
        let monitor = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: queue)
        monitor.setEventHandler { underPressure.withLock { $0 = true } }
        monitor.resume()
        defer { monitor.cancel() }

        // Both limits scale with the machine: a flat 512 MB reserve on an 8 GB
        // Mac pushes everything else into swap, which reads as a freeze.
        let physical = ProcessInfo.processInfo.physicalMemory
        let reserve = max(768 * 1024 * 1024, UInt64(Double(physical) * 0.18))
        let ceiling = physical <= 9 * 1024 * 1024 * 1024 ? 0.45 : 0.7
        let chunk: vm_size_t = 256 * 1024 * 1024

        for _ in 0..<2 {
            if underPressure.withLock({ $0 }) { break }
            let reclaimable = reclaimableBytes()
            guard reclaimable > reserve else { break }
            let target = min(reclaimable - reserve, UInt64(Double(physical) * ceiling))

            var regions: [vm_address_t] = []
            var claimed: UInt64 = 0
            while claimed < target {
                // Checked every chunk, not once per pass: "reclaimable" includes
                // dirty pages whose eviction costs a compressor round-trip, and
                // without this the loop can squeeze free memory to nothing.
                guard !underPressure.withLock({ $0 }), freeBytes() > reserve else { break }
                var address: vm_address_t = 0
                guard vm_allocate(mach_task_self_, &address, chunk, VM_FLAGS_ANYWHERE) == KERN_SUCCESS,
                      let pointer = UnsafeMutableRawPointer(bitPattern: address)
                else { break }
                memset(pointer, 1, Int(chunk))     // an untouched page is never really claimed
                regions.append(address)
                claimed += UInt64(chunk)
            }
            for address in regions { vm_deallocate(mach_task_self_, address, chunk) }
            usleep(300_000)                        // let the counters settle
            if claimed < UInt64(chunk) { break }   // nothing left to win
        }
        return freeBytes()
    }
}
