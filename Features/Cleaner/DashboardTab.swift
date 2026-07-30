import SwiftUI
import Observation

/// Keeps one live `SystemSample` for the dashboard.
///
/// The loop is structured: the view starts it with `.task`, so closing the
/// window cancels it and nothing keeps sampling behind a window nobody is
/// looking at. Each reading is a handful of syscalls measured in microseconds,
/// which is why they run right here on the main actor instead of paying for a
/// thread hop.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var sample = SystemSample()
    private var previous = SystemCounters()

    /// Sample once a second until cancelled.
    func run() async {
        previous = SystemStats.counters()
        update()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            update()
        }
    }

    /// Take a reading now — used after a memory clean, so the numbers move the
    /// moment the work finishes rather than up to a second later.
    func update() {
        let current = SystemStats.counters()
        sample = SystemStats.sample(from: previous, to: current,
                                    memory: SystemStats.memory(), disk: SystemStats.disk())
        previous = current
    }
}

struct DashboardTab: View {
    @State private var monitor = SystemMonitor()
    @State private var isCleaning = false
    @State private var result: String?

    private var sample: SystemSample { monitor.sample }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    health
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        StatTile(symbol: "cpu", title: "Processor",
                                 value: "\(Int((sample.cpuBusy * 100).rounded()))%",
                                 detail: "busy", fill: sample.cpuBusy)
                        StatTile(symbol: "memorychip", title: "Memory",
                                 value: SystemStats.format(sample.memoryUsed),
                                 detail: "of \(SystemStats.format(sample.memoryTotal)) used",
                                 fill: fraction(sample.memoryUsed, sample.memoryTotal))
                        StatTile(symbol: "internaldrive", title: "Disk",
                                 value: SystemStats.format(sample.diskFree),
                                 detail: "free of \(SystemStats.format(sample.diskTotal))",
                                 fill: 1 - fraction(sample.diskFree, sample.diskTotal))
                        StatTile(symbol: "network", title: "Network",
                                 value: "↓ \(SystemStats.format(sample.networkIn))/s",
                                 detail: "↑ \(SystemStats.format(sample.networkOut))/s", fill: nil)
                    }
                }
                .padding(16)
            }

            CleanerActionBar(summary: result ?? "\(SystemStats.format(sample.memoryFree)) memory free right now",
                             title: "Free Up Memory", isEnabled: true, isBusy: isCleaning) {
                Task { await freeMemory() }
            }
        }
        .task { await monitor.run() }
    }

    private var health: some View {
        GroupBox {
            HStack(spacing: 18) {
                Gauge(value: Double(sample.health), in: 0...100) {
                    Text("Health")
                } currentValueLabel: {
                    Text("\(sample.health)").monospacedDigit()
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(cleanerScoreColor(sample.health))
                .accessibilityLabel("System health \(sample.health) out of 100")

                VStack(alignment: .leading, spacing: 4) {
                    Text("System health").fontWeight(.semibold)
                    Text(verdict)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
        }
    }

    private var verdict: String {
        switch sample.health {
        case 70...: "Plenty of room. Nothing needs doing."
        case 40..<70: "Getting tight — the Clean tab is where the easy wins are."
        default: "Low on memory or disk. Clean and Developer both have space to recover."
        }
    }

    private func fraction(_ part: UInt64, _ whole: UInt64) -> Double {
        whole > 0 ? min(1, Double(part) / Double(whole)) : 0
    }

    private func freeMemory() async {
        isCleaning = true
        result = nil
        let (before, after) = await RAMCleaner.clean()
        monitor.update()
        isCleaning = false
        result = after > before
            ? "Freed \(SystemStats.format(after - before))"
            : "Already as free as macOS will make it"
    }
}

private struct StatTile: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String
    /// 0…1 of the bar under the number, or nil for a figure with no ceiling.
    let fill: Double?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let fill {
                    ProgressView(value: min(1, max(0, fill)))
                        .tint(cleanerScoreColor(Int((1 - fill) * 100)))
                        .labelsHidden()
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value) \(detail)")
    }
}
