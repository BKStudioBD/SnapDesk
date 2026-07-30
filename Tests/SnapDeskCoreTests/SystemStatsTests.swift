import Testing
import Foundation
@testable import SnapDeskCore

/// The dashboard's arithmetic. Reading the kernel is Apple's job; turning two
/// readings into a percentage is ours, and that is what can be wrong.
struct SystemStatsTests {

    private func counters(idle: UInt64, total: UInt64,
                          bytesIn: UInt64 = 0, bytesOut: UInt64 = 0,
                          at time: TimeInterval = 0) -> SystemCounters {
        SystemCounters(cpuIdleTicks: idle, cpuTotalTicks: total,
                       bytesIn: bytesIn, bytesOut: bytesOut, timestamp: time)
    }

    @Test("Busy is the share of ticks that were not idle")
    func cpuBusy() {
        let sample = SystemStats.sample(from: counters(idle: 100, total: 200),
                                        to: counters(idle: 125, total: 300),
                                        memory: (0, 0), disk: (0, 0))
        // 100 ticks passed, 25 of them idle → 75% busy.
        #expect(abs(sample.cpuBusy - 0.75) < 0.0001)
    }

    @Test("A fully idle interval reads as zero busy, not as missing data")
    func cpuIdle() {
        let sample = SystemStats.sample(from: counters(idle: 100, total: 200),
                                        to: counters(idle: 200, total: 300),
                                        memory: (0, 0), disk: (0, 0))
        #expect(sample.cpuBusy == 0)
    }

    @Test("Counters that went backwards report nothing rather than a wild figure")
    func cpuCountersReset() {
        // Waking from sleep, or a counter that wrapped: the later reading is
        // SMALLER. Unsigned subtraction there would trap or produce nonsense.
        let sample = SystemStats.sample(from: counters(idle: 500, total: 900),
                                        to: counters(idle: 100, total: 200),
                                        memory: (0, 0), disk: (0, 0))
        #expect(sample.cpuBusy == 0)
    }

    @Test("Network is a rate, so the same bytes over twice the time is half the speed")
    func networkRate() {
        let fast = SystemStats.sample(from: counters(idle: 0, total: 0, bytesIn: 0, at: 0),
                                      to: counters(idle: 0, total: 0, bytesIn: 2_000, at: 1),
                                      memory: (0, 0), disk: (0, 0))
        let slow = SystemStats.sample(from: counters(idle: 0, total: 0, bytesIn: 0, at: 0),
                                      to: counters(idle: 0, total: 0, bytesIn: 2_000, at: 2),
                                      memory: (0, 0), disk: (0, 0))
        #expect(fast.networkIn == 2_000)
        #expect(slow.networkIn == 1_000)
    }

    @Test("Two readings at the same instant don't divide by zero")
    func networkZeroInterval() {
        let sample = SystemStats.sample(from: counters(idle: 0, total: 0, bytesIn: 0, at: 5),
                                        to: counters(idle: 0, total: 0, bytesIn: 9_000, at: 5),
                                        memory: (0, 0), disk: (0, 0))
        #expect(sample.networkIn == 0)
        #expect(sample.networkOut == 0)
    }

    @Test("Memory and disk are carried through as given")
    func passesThroughMemoryAndDisk() {
        let sample = SystemStats.sample(from: counters(idle: 0, total: 0),
                                        to: counters(idle: 0, total: 0),
                                        memory: (used: 8_000, total: 16_000),
                                        disk: (free: 300, total: 1_000))
        #expect(sample.memoryUsed == 8_000)
        #expect(sample.memoryFree == 8_000)
        #expect(sample.diskFree == 300)
    }

    @Test("An empty machine scores 100 and a full, pegged one scores 0")
    func healthBounds() {
        let idle = SystemSample(cpuBusy: 0, memoryUsed: 0, memoryTotal: 16,
                                diskFree: 100, diskTotal: 100)
        #expect(idle.health == 100)

        let pegged = SystemSample(cpuBusy: 1, memoryUsed: 16, memoryTotal: 16,
                                  diskFree: 0, diskTotal: 100)
        #expect(pegged.health == 0)
    }

    @Test("Free memory is weighted heaviest — it is what the cleaner can move")
    func healthWeighting() {
        // Same machine, once short on memory and once short on disk. The memory
        // case must score lower, or the dashboard would send people to the wrong
        // tab.
        let lowMemory = SystemSample(cpuBusy: 0, memoryUsed: 16, memoryTotal: 16,
                                     diskFree: 100, diskTotal: 100)
        let lowDisk = SystemSample(cpuBusy: 0, memoryUsed: 0, memoryTotal: 16,
                                   diskFree: 0, diskTotal: 100)
        #expect(lowMemory.health < lowDisk.health)
    }

    @Test("A machine reporting no total capacity scores that part as zero, not as full")
    func healthWithNoTotals() {
        let unknown = SystemSample(cpuBusy: 0, memoryUsed: 0, memoryTotal: 0,
                                   diskFree: 0, diskTotal: 0)
        #expect(unknown.health == 30)      // only the idle-CPU third can be earned
    }
}
