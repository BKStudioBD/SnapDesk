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
        VStack(spacing: 14) {
            CleanerCard {
                HStack(spacing: 20) {
                    HealthRing(score: sample.health)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("System health").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CleanerTheme.text)
                        Text(verdict).font(.system(size: 12)).foregroundStyle(CleanerTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let result {
                            Text(result).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(CleanerTheme.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
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

            Spacer(minLength: 0)

            CleanerActionBar(summary: "\(SystemStats.format(sample.memoryFree)) memory free right now",
                             title: "Free up memory", isEnabled: true, isBusy: isCleaning) {
                Task { await freeMemory() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(16)
        .task { await monitor.run() }
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

/// The score, drawn as a ring and written as a number — the ring alone would be
/// colour carrying meaning.
private struct HealthRing: View {
    let score: Int

    var body: some View {
        ZStack {
            Circle().stroke(CleanerTheme.line, lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(CleanerTheme.gauge(score), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)").font(.system(size: 24, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(CleanerTheme.text)
                Text("/100").font(.system(size: 10)).foregroundStyle(CleanerTheme.muted)
            }
        }
        .frame(width: 84, height: 84)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("System health \(score) out of 100")
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
        CleanerCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(CleanerTheme.muted)
                    Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.5)
                        .foregroundStyle(CleanerTheme.muted)
                }
                Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(CleanerTheme.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(detail).font(.system(size: 11)).foregroundStyle(CleanerTheme.muted).lineLimit(1)
                if let fill {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(CleanerTheme.line)
                            Capsule().fill(CleanerTheme.gauge(Int((1 - fill) * 100)))
                                .frame(width: geometry.size.width * CGFloat(min(1, max(0, fill))))
                        }
                    }
                    .frame(height: 4)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value) \(detail)")
    }
}
