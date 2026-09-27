#if !os(watchOS)
import SwiftUI

/// Shows one day of metrics: launch and hang percentiles, resource use and
/// exit reasons.
public struct MetricDetailView: View {
    let metrics: MetricPayload

    public init(metrics: MetricPayload) {
        self.metrics = metrics
    }

    public var body: some View {
        List {
            Section("Responsiveness") {
                histogramRow("Launch", metrics.launchTime)
                histogramRow("Optimized Launch", metrics.optimizedLaunchTime)
                histogramRow("Resume", metrics.resumeTime)
                histogramRow("Hangs", metrics.hangTime)
                valueRow("Scroll Hitches", metrics.scrollHitchTimeRatio)
            }
            Section("Resources") {
                valueRow("CPU Time", metrics.cumulativeCPUTime)
                valueRow("Peak Memory", metrics.peakMemoryUsage)
                valueRow("Suspended Memory", metrics.averageSuspendedMemory)
                valueRow("Disk Writes", metrics.cumulativeLogicalWrites)
                valueRow("Wi-Fi Download", metrics.cumulativeWifiDownload)
                valueRow("Cellular Download", metrics.cumulativeCellularDownload)
                valueRow("Foreground Time", metrics.cumulativeForegroundTime)
                valueRow("Background Time", metrics.cumulativeBackgroundTime)
            }
            exitSection("Foreground Exits", metrics.foregroundExits)
            exitSection("Background Exits", metrics.backgroundExits)
            if let meta = metrics.metadata {
                Section("Device") {
                    if let version = metrics.appVersion { LabeledContent("Version", value: version) }
                    if let os = meta.osVersion { LabeledContent("OS", value: os) }
                    if let device = meta.deviceType { LabeledContent("Device", value: device) }
                }
            }
        }
        .navigationTitle(metrics.timeStampEnd?.formatted(date: .abbreviated, time: .omitted) ?? "Metrics")
    }

    @ViewBuilder
    private func histogramRow(_ label: String, _ histogram: Histogram?) -> some View {
        if let histogram, let median = histogram.percentile(0.5) {
            LabeledContent(label) {
                Text("p50 \(Self.format(median)) · p95 \(Self.format(histogram.percentile(0.95) ?? median))")
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func valueRow(_ label: String, _ value: MetricValue?) -> some View {
        if let value {
            LabeledContent(label, value: value.formatted)
        }
    }

    @ViewBuilder
    private func exitSection(_ title: String, _ counts: [String: Int]) -> some View {
        if !counts.isEmpty {
            Section(title) {
                ForEach(counts.sorted { $0.value > $1.value }, id: \.key) { key, count in
                    LabeledContent(Self.exitName(key), value: "\(count)")
                }
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }

    /// `"cumulativeMemoryResourceLimitExitCount"` → `"Memory Resource Limit"`.
    static func exitName(_ key: String) -> String {
        var name = key
        if name.hasPrefix("cumulative") { name.removeFirst("cumulative".count) }
        if name.hasSuffix("ExitCount") { name.removeLast("ExitCount".count) }
        var words = ""
        for character in name {
            if character.isUppercase, !words.isEmpty, words.last != " " { words.append(" ") }
            words.append(character)
        }
        return words
            .replacingOccurrences(of: "C P U", with: "CPU")
            .replacingOccurrences(of: "U R L", with: "URL")
    }
}
#endif
