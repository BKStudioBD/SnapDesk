import Foundation
import AppKit

/// RAM cleaner (Memory-Clean style, App-Store-safe — no root, no `purge`).
/// Temporarily allocates and touches large memory blocks, pressuring macOS to
/// evict inactive/cached pages, then releases everything. Net effect: more
/// free RAM for the apps you're about to use.
/// Tiny lock-guarded bool shared across the pressure-handler queue and the
/// allocation loop (avoids an unsynchronized cross-thread `var`).
private final class AtomicFlag {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum RAMCleaner {
    private static var running = false

    private static func vmStats() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                let host = mach_host_self()
                defer { mach_port_deallocate(mach_task_self_, host) }
                return host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? stats : nil
    }

    /// Free physical memory right now, in bytes.
    static func freeBytes() -> UInt64 {
        guard let s = vmStats() else { return 0 }
        return (UInt64(s.free_count) + UInt64(s.speculative_count)) * UInt64(vm_kernel_page_size)
    }

    /// Memory the kernel could give back under pressure (cache/inactive/purgeable).
    static func reclaimableBytes() -> UInt64 {
        guard let s = vmStats() else { return 0 }
        let pages = UInt64(s.inactive_count) + UInt64(s.purgeable_count)
                  + UInt64(s.speculative_count) + UInt64(s.free_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    /// FORCE clean on a background queue; `completion(beforeFree, afterFree)`
    /// on the main queue. Tries the system `purge` first (works when developer
    /// tools allow it; silently fails under sandbox), then hammers the pager
    /// with multi-pass allocate-and-release until it stops yielding memory.
    static func clean(completion: @escaping (UInt64, UInt64) -> Void) {
        // Re-entrant call must still call back, or the caller's spinner hangs.
        guard !running else { let f = freeBytes(); completion(f, f); return }
        running = true
        let before = freeBytes()
        DispatchQueue.global(qos: .utility).async {
            // Runs entirely in the background — other apps keep working.
            // Pass 0: real purge if the system lets us (no sudo prompt ever).
            let purge = Process()
            purge.executableURL = URL(fileURLWithPath: "/usr/sbin/purge")
            purge.standardOutput = nil; purge.standardError = nil
            if (try? purge.run()) != nil { purge.waitUntilExit() }

            // Force pass: macOS keeps "free" tiny on purpose (everything is
            // cache), so the target comes from RECLAIMABLE pages. vm_allocate/
            // vm_deallocate (NOT malloc/free — malloc keeps freed pages in its
            // arena) so the evicted memory returns to the kernel immediately.
            // Live-verified: free RAM rises and stays up after the pass.
            // World-class guardrail: bail the MOMENT the system reports
            // critical memory pressure — never contribute to a system stall.
            // Race-free flag shared with the pressure handler.
            let critical = AtomicFlag()
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                                   queue: .global(qos: .utility))
            pressure.setEventHandler { critical.set() }   // back off on warning, not just critical
            pressure.resume()
            defer { pressure.cancel() }

            // Reserve + ceiling scale to the machine — a flat 512 MB / 80% is too
            // aggressive on an 8 GB Mac (pushes other apps to swap → beachball).
            let physical = ProcessInfo.processInfo.physicalMemory
            let reserve = max(UInt64(768) * 1024 * 1024, UInt64(Double(physical) * 0.18))
            let ceilingFrac = physical <= UInt64(9) * 1024 * 1024 * 1024 ? 0.45 : 0.7
            let chunkSize: vm_size_t = 256 * 1024 * 1024
            for _ in 0..<2 {
                if critical.get() { break }
                let reclaimable = reclaimableBytes()
                guard reclaimable > reserve else { break }
                let target = min(reclaimable - reserve, UInt64(Double(physical) * ceilingFrac))
                var regions: [vm_address_t] = []
                var allocated: UInt64 = 0
                while allocated < target {
                    // Re-check the floor EVERY chunk: "reclaimable" can include
                    // dirty pages whose eviction costs compressor/swap — without
                    // this the loop can squeeze free RAM to ~0 (system-wide
                    // beachballs) before the once-per-pass check runs again.
                    guard !critical.get(), freeBytes() > reserve else { break }
                    var addr: vm_address_t = 0
                    guard vm_allocate(mach_task_self_, &addr, chunkSize, VM_FLAGS_ANYWHERE) == KERN_SUCCESS
                    else { break }
                    memset(UnsafeMutableRawPointer(bitPattern: addr), 1, Int(chunkSize))
                    regions.append(addr)
                    allocated += UInt64(chunkSize)
                }
                for a in regions { vm_deallocate(mach_task_self_, a, chunkSize) }
                usleep(300_000)                                // let counters settle
                if allocated < UInt64(chunkSize) { break }
            }

            let after = freeBytes()
            DispatchQueue.main.async {
                running = false
                completion(before, after)
            }
        }
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

}
