import Foundation
import Darwin

/// One reading of how loaded the machine is: processor, memory, disk and the
/// network throughput since the previous reading.
///
/// A plain value, so the sampling code has no state a view can see half-written
/// and the health arithmetic can be tested without a machine under load.
struct SystemSample: Sendable, Equatable {
    /// 0…1. The share of processor time that was NOT idle since the last sample.
    var cpuBusy: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var diskFree: UInt64 = 0
    var diskTotal: UInt64 = 0
    /// Bytes per second across the physical interfaces, since the last sample.
    var networkIn: UInt64 = 0
    var networkOut: UInt64 = 0

    var memoryFree: UInt64 { memoryTotal > memoryUsed ? memoryTotal - memoryUsed : 0 }

    /// 0…100. Free memory counts most because it is what the cleaner can move,
    /// then free disk, then an idle processor: a busy CPU is usually the user's
    /// own work and not something to fix.
    var health: Int {
        func fraction(_ part: UInt64, _ whole: UInt64) -> Double {
            whole > 0 ? min(1, Double(part) / Double(whole)) : 0
        }
        let score = fraction(memoryFree, memoryTotal) * 0.4
                  + fraction(diskFree, diskTotal) * 0.3
                  + (1 - min(1, max(0, cpuBusy))) * 0.3
        return Int((score * 100).rounded())
    }
}

/// Raw counters read straight from the kernel. Kept apart from `SystemSample`
/// because they are only useful as a difference between two readings.
struct SystemCounters: Sendable, Equatable {
    var cpuIdleTicks: UInt64 = 0
    var cpuTotalTicks: UInt64 = 0
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var timestamp: TimeInterval = 0
}

/// Reads the machine's vital signs. Every call is a syscall measured in
/// microseconds, so there is no background queue here. The cost of hopping
/// threads would exceed the cost of the read.
enum SystemStats {

    // MARK: - Processor

    /// Cumulative processor ticks since boot: (idle, total).
    static func cpuTicks() -> (idle: UInt64, total: UInt64) {
        var info = host_cpu_load_info()
        // HOST_CPU_LOAD_INFO_COUNT is a C macro and does not reach Swift, so the
        // count is derived from the struct's own layout.
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                let host = mach_host_self()
                defer { mach_port_deallocate(mach_task_self_, host) }
                return host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let idle = UInt64(info.cpu_ticks.2)      // CPU_STATE_IDLE
        let total = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1)
                  + idle + UInt64(info.cpu_ticks.3)
        return (idle, total)
    }

    // MARK: - Memory

    /// Memory in use right now, and the machine's total. "Used" is what macOS's
    /// own Memory Used figure counts: active + wired + compressed. Inactive and
    /// speculative pages are cache the kernel hands back on demand, so counting
    /// them as used would report a healthy Mac as full.
    static func memory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
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
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    // MARK: - Disk

    /// Free and total bytes on the boot volume. "Important usage" is the figure
    /// Finder shows. It counts purgeable space the system would reclaim for a
    /// real write, which a raw `volumeAvailableCapacity` does not.
    ///
    /// The one reading in here that is NOT microseconds: totting up purgeable
    /// and snapshot space takes tens to hundreds of milliseconds, so call
    /// `diskInBackground()` from anything that samples on a timer.
    static func disk() -> (free: UInt64, total: UInt64) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ]) else { return (0, 0) }
        let free = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
        let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
        return (free, total)
    }

    /// The same reading off the main actor. It blocks on the volume rather than
    /// suspending, which is a dispatch queue's job and not the cooperative
    /// pool's: see `BackgroundWork`.
    static func diskInBackground() async -> (free: UInt64, total: UInt64) {
        await BackgroundWork.run { disk() }
    }

    // MARK: - Network

    /// Cumulative bytes in/out across physical interfaces since boot. Only en*
    /// (Ethernet, Wi-Fi) and pdp_ip* (cellular) are counted: loopback and the
    /// virtual utun/bridge interfaces double-count the same traffic.
    static func networkBytes() -> (in: UInt64, out: UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }

        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let raw = interface.ifa_data else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            bytesIn += UInt64(data.ifi_ibytes)
            bytesOut += UInt64(data.ifi_obytes)
        }
        return (bytesIn, bytesOut)
    }

    // MARK: - Sampling

    /// Everything at once, as the raw cumulative counters.
    static func counters() -> SystemCounters {
        let cpu = cpuTicks()
        let network = networkBytes()
        return SystemCounters(cpuIdleTicks: cpu.idle, cpuTotalTicks: cpu.total,
                              bytesIn: network.in, bytesOut: network.out,
                              timestamp: ProcessInfo.processInfo.systemUptime)
    }

    /// Turn two counter readings into a sample. Pure arithmetic. The rate math
    /// (including a counter that wrapped or a machine that woke from sleep) is
    /// tested without touching the kernel.
    static func sample(from previous: SystemCounters, to current: SystemCounters,
                       memory: (used: UInt64, total: UInt64),
                       disk: (free: UInt64, total: UInt64)) -> SystemSample {
        var out = SystemSample()
        out.memoryUsed = memory.used
        out.memoryTotal = memory.total
        out.diskFree = disk.free
        out.diskTotal = disk.total

        let totalDelta = current.cpuTotalTicks >= previous.cpuTotalTicks
            ? current.cpuTotalTicks - previous.cpuTotalTicks : 0
        let idleDelta = current.cpuIdleTicks >= previous.cpuIdleTicks
            ? current.cpuIdleTicks - previous.cpuIdleTicks : 0
        if totalDelta > 0 {
            out.cpuBusy = min(1, max(0, 1 - Double(idleDelta) / Double(totalDelta)))
        }

        let seconds = current.timestamp - previous.timestamp
        if seconds > 0 {
            if current.bytesIn >= previous.bytesIn {
                out.networkIn = UInt64(Double(current.bytesIn - previous.bytesIn) / seconds)
            }
            if current.bytesOut >= previous.bytesOut {
                out.networkOut = UInt64(Double(current.bytesOut - previous.bytesOut) / seconds)
            }
        }
        return out
    }

    /// "1.2 GB". The Finder-style figure, used everywhere in the cleaner so a
    /// size never reads differently in two places.
    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
