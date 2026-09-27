import Foundation

/// A MetricKit daily metrics payload.
///
/// Common metrics are exposed as typed properties; everything else remains
/// available through ``raw``.
public struct MetricPayload: Sendable, Hashable, Identifiable {
    public var id: String
    public var timeStampBegin: Date?
    public var timeStampEnd: Date?
    public var appVersion: String?
    /// Metadata about the device and build (the same fields as diagnostics).
    public var metadata: DiagnosticMetadata?
    public var raw: JSONValue

    /// Parses the JSON produced by `MXMetricPayload.jsonRepresentation()`.
    public init(json data: Data) throws {
        let root = try JSONParser.parse(data)
        guard root.objectValue != nil else { throw PostmortemError.invalidPayload("the payload isn't a JSON object") }
        raw = root
        timeStampBegin = root["timeStampBegin"]?.stringValue.flatMap(PayloadDate.parse)
        timeStampEnd = root["timeStampEnd"]?.stringValue.flatMap(PayloadDate.parse)
        appVersion = root["appVersion"]?.stringValue
        metadata = root["metaData"].map(DiagnosticMetadata.init(json:))
        id = Diagnostic.identifier(kind: .appLaunch, json: .object(["metrics": root]))
    }

    // MARK: - CPU, memory, time

    public var cumulativeCPUTime: MetricValue? { value("cpuMetrics", "cumulativeCPUTime") }
    public var cumulativeCPUInstructions: MetricValue? { value("cpuMetrics", "cumulativeCPUInstructions") }
    public var peakMemoryUsage: MetricValue? { value("memoryMetrics", "peakMemoryUsage") }
    public var averageSuspendedMemory: MetricValue? { value("memoryMetrics", "averageSuspendedMemory", "averageValue") }
    public var cumulativeForegroundTime: MetricValue? { value("applicationTimeMetrics", "cumulativeForegroundTime") }
    public var cumulativeBackgroundTime: MetricValue? { value("applicationTimeMetrics", "cumulativeBackgroundTime") }
    public var cumulativeLogicalWrites: MetricValue? { value("diskIOMetrics", "cumulativeLogicalWrites") }
    public var scrollHitchTimeRatio: MetricValue? { value("animationMetrics", "scrollHitchTimeRatio") }
    public var hitchTimeRatio: MetricValue? { value("animationMetrics", "hitchTimeRatio") }
    public var cumulativeWifiDownload: MetricValue? { value("networkTransferMetrics", "cumulativeWifiDownload") }
    public var cumulativeCellularDownload: MetricValue? { value("networkTransferMetrics", "cumulativeCellularDownload") }

    // MARK: - Launch and responsiveness

    /// Time to first draw after launch.
    public var launchTime: Histogram? { histogram("applicationLaunchMetrics", "histogrammedTimeToFirstDrawKey") }
    /// Time to first draw with prewarming (iOS 15+).
    public var optimizedLaunchTime: Histogram? { histogram("applicationLaunchMetrics", "histogrammedOptimizedTimeToFirstDrawKey") }
    public var resumeTime: Histogram? { histogram("applicationLaunchMetrics", "histogrammedResumeTime") }
    public var extendedLaunchTime: Histogram? { histogram("applicationLaunchMetrics", "histogrammedExtendedLaunch") }
    public var hangTime: Histogram? { histogram("applicationResponsivenessMetrics", "histogrammedAppHangTime") }

    // MARK: - Exits

    /// Foreground exit counts by reason, for example
    /// `["cumulativeMemoryResourceLimitExitCount": 2]`. Only non-zero
    /// counts are reported.
    public var foregroundExits: [String: Int] { counts("applicationExitMetrics", "foregroundExitData") }
    public var backgroundExits: [String: Int] { counts("applicationExitMetrics", "backgroundExitData") }

    /// Abnormal exits (every reason except normal exits), foreground and background.
    public var abnormalExitCount: Int {
        (foregroundExits.merging(backgroundExits, uniquingKeysWith: +))
            .filter { $0.key != "cumulativeNormalAppExitCount" }
            .values.reduce(0, +)
    }

    // MARK: - Helpers

    private func node(_ path: [String]) -> JSONValue? {
        path.reduce(Optional(raw)) { $0?[$1] }
    }

    private func value(_ path: String...) -> MetricValue? {
        node(path)?.metricValue
    }

    private func histogram(_ path: String...) -> Histogram? {
        node(path).flatMap(Histogram.init(json:))
    }

    private func counts(_ path: String...) -> [String: Int] {
        (node(path)?.objectValue ?? [:]).compactMapValues(\.intValue)
    }
}

/// A MetricKit histogram, such as launch times.
public struct Histogram: Sendable, Hashable {
    public struct Bucket: Sendable, Hashable {
        public var start: MetricValue
        public var end: MetricValue
        public var count: Int
    }

    /// Buckets in ascending order.
    public var buckets: [Bucket]

    public init(buckets: [Bucket]) {
        self.buckets = buckets
    }

    init?(json: JSONValue) {
        guard let values = json["histogramValue"]?.objectValue else { return nil }
        buckets = values
            .sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
            .compactMap { _, bucket in
                guard let start = bucket["bucketStart"]?.metricValue, let end = bucket["bucketEnd"]?.metricValue else { return nil }
                return Bucket(start: start, end: end, count: bucket["bucketCount"]?.intValue ?? 0)
            }
    }

    public var totalCount: Int { buckets.reduce(0) { $0 + $1.count } }

    /// Estimates a percentile (0...1) in seconds by interpolating within
    /// the bucket that contains it. Returns `nil` for non-duration histograms.
    public func percentile(_ fraction: Double) -> Double? {
        let total = totalCount
        guard total > 0 else { return nil }
        let target = fraction.clamped(to: 0...1) * Double(total)
        var seen = 0.0
        for bucket in buckets {
            guard let start = bucket.start.seconds, let end = bucket.end.seconds else { return nil }
            let next = seen + Double(bucket.count)
            if target <= next, bucket.count > 0 {
                let within = (target - seen) / Double(bucket.count)
                return start + (end - start) * within
            }
            seen = next
        }
        return buckets.last?.end.seconds
    }
}
