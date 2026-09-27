import CryptoKit
import Foundation

/// A MetricKit diagnostic payload: the crashes, hangs and exceptions
/// reported for one period.
public struct DiagnosticPayload: Sendable, Hashable {
    public var timeStampBegin: Date?
    public var timeStampEnd: Date?
    public var diagnostics: [Diagnostic]

    public init(timeStampBegin: Date? = nil, timeStampEnd: Date? = nil, diagnostics: [Diagnostic]) {
        self.timeStampBegin = timeStampBegin
        self.timeStampEnd = timeStampEnd
        self.diagnostics = diagnostics
    }

    /// Parses the JSON produced by `MXDiagnosticPayload.jsonRepresentation()`.
    public init(json data: Data) throws {
        let root = try JSONParser.parse(data)
        guard let object = root.objectValue else { throw PostmortemError.invalidPayload("the payload isn't a JSON object") }
        timeStampBegin = object["timeStampBegin"]?.stringValue.flatMap(PayloadDate.parse)
        timeStampEnd = object["timeStampEnd"]?.stringValue.flatMap(PayloadDate.parse)
        var diagnostics: [Diagnostic] = []
        for kind in Diagnostic.Kind.allCases {
            for entry in object[kind.payloadKey]?.arrayValue ?? [] {
                diagnostics.append(try Diagnostic(kind: kind, json: entry, periodEnd: timeStampEnd))
            }
        }
        self.diagnostics = diagnostics
    }
}

/// An error reading a payload.
public enum PostmortemError: Error, Sendable, Equatable, LocalizedError {
    case invalidPayload(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPayload(let reason): "Invalid MetricKit payload: \(reason)"
        }
    }
}

/// One crash, hang, CPU exception, disk write exception or slow launch.
public struct Diagnostic: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable, Codable {
        case crash
        case hang
        case cpuException
        case diskWriteException
        case appLaunch

        var payloadKey: String {
            switch self {
            case .crash: "crashDiagnostics"
            case .hang: "hangDiagnostics"
            case .cpuException: "cpuExceptionDiagnostics"
            case .diskWriteException: "diskWriteExceptionDiagnostics"
            case .appLaunch: "appLaunchDiagnostics"
            }
        }

        /// A display name, such as "Crash" or "CPU Exception".
        public var displayName: String {
            switch self {
            case .crash: "Crash"
            case .hang: "Hang"
            case .cpuException: "CPU Exception"
            case .diskWriteException: "Disk Write Exception"
            case .appLaunch: "Slow Launch"
            }
        }
    }

    /// A stable identifier derived from the diagnostic's contents, so the
    /// same report delivered twice is recognized.
    public var id: String
    public var kind: Kind
    public var metadata: DiagnosticMetadata
    public var stackTrace: StackTrace?
    /// The hang type, such as "Main Runloop Hang", for hangs.
    public var hangType: String?
    public var version: String?
    /// The end of the reporting period the diagnostic was delivered in. The
    /// exact time of the event isn't reported.
    public var periodEnd: Date?
    /// The diagnostic as MetricKit reported it.
    public var raw: JSONValue

    init(kind: Kind, json: JSONValue, periodEnd: Date?) throws {
        guard let object = json.objectValue else { throw PostmortemError.invalidPayload("a \(kind.payloadKey) entry isn't an object") }
        self.kind = kind
        self.raw = json
        self.periodEnd = periodEnd
        metadata = DiagnosticMetadata(json: object["diagnosticMetaData"] ?? .object([:]))
        stackTrace = object["callStackTree"].map(StackTrace.init(json:))
        hangType = object["hangType"]?.stringValue
        version = object["version"]?.stringValue
        id = Self.identifier(kind: kind, json: json)
    }

    static func identifier(kind: Kind, json: JSONValue) -> String {
        let data = json.canonicalData()
        let digest = SHA256.hash(data: Data(kind.rawValue.utf8) + data)
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// A one-line title, such as `"EXC_BAD_ACCESS (SIGSEGV)"`,
    /// `"NSRangeException"` or `"Hang 4 s"`.
    public var title: String {
        switch kind {
        case .crash: CrashExplanation(metadata).title
        case .hang: "Hang \(metadata.hangDuration?.formatted ?? "")".trimmingCharacters(in: .whitespaces)
        case .cpuException: "CPU \(metadata.totalCPUTime?.formatted ?? "?") in \(metadata.totalSampledTime?.formatted ?? "?")"
        case .diskWriteException: "Wrote \(metadata.writesCaused?.formatted ?? "?")"
        case .appLaunch: "Launch took \(metadata.launchDuration?.formatted ?? "?")"
        }
    }

    /// A plain-language explanation of what happened.
    public var summary: String {
        switch kind {
        case .crash:
            return CrashExplanation(metadata).summary
        case .hang:
            let type = hangType.map { " (\($0))" } ?? ""
            return "The app didn't respond to input for \(metadata.hangDuration?.formatted ?? "a while")\(type). The stack shows what the main thread was doing."
        case .cpuException:
            return "The app used \(metadata.totalCPUTime?.formatted ?? "too much") of CPU time within \(metadata.totalSampledTime?.formatted ?? "a short period"), exceeding the system's limit. The stack shows where the time was spent."
        case .diskWriteException:
            return "The app wrote \(metadata.writesCaused?.formatted ?? "too much data") to disk within 24 hours, exceeding the system's limit. The stack shows where the writes came from."
        case .appLaunch:
            return "Launch took \(metadata.launchDuration?.formatted ?? "too long"). The stack shows what the app was doing during launch."
        }
    }

    /// The most relevant frames: the crashing thread's backtrace, or the
    /// heaviest sampled path for aggregated diagnostics.
    public var primaryFrames: [StackTrace.Frame] {
        guard let trace = stackTrace, let thread = trace.attributedThread else { return [] }
        return trace.callStackPerThread ? thread.frames : thread.heaviestPath
    }
}

/// Metadata reported with a diagnostic. Fields not modeled here are in
/// ``extra``.
public struct DiagnosticMetadata: Sendable, Hashable {
    public var appVersion: String?
    public var appBuildVersion: String?
    public var bundleIdentifier: String?
    public var osVersion: String?
    public var deviceType: String?
    public var platformArchitecture: String?
    public var regionFormat: String?
    public var pid: Int?
    public var isTestFlightApp: Bool?
    public var lowPowerModeEnabled: Bool?

    // Crashes
    public var exceptionType: Int?
    public var exceptionCode: Int?
    public var signal: Int?
    public var terminationReason: String?
    public var virtualMemoryRegionInfo: String?
    public var objectiveCException: ObjectiveCExceptionReason?

    // Hangs, exceptions and launches
    public var hangDuration: MetricValue?
    public var totalCPUTime: MetricValue?
    public var totalSampledTime: MetricValue?
    public var writesCaused: MetricValue?
    public var launchDuration: MetricValue?

    /// Keys that aren't modeled.
    public var extra: [String: JSONValue]

    static let modeledKeys: Set<String> = [
        "appVersion", "appBuildVersion", "bundleIdentifier", "osVersion", "deviceType", "platformArchitecture",
        "regionFormat", "pid", "isTestFlightApp", "lowPowerModeEnabled", "exceptionType", "exceptionCode", "signal",
        "terminationReason", "virtualMemoryRegionInfo", "objectiveCexceptionReason", "hangDuration", "totalCPUTime",
        "totalSampledTime", "writesCaused", "launchDuration",
    ]

    public init(json: JSONValue) {
        let object = json.objectValue ?? [:]
        appVersion = object["appVersion"]?.stringValue
        appBuildVersion = object["appBuildVersion"]?.stringValue
        bundleIdentifier = object["bundleIdentifier"]?.stringValue
        osVersion = object["osVersion"]?.stringValue
        deviceType = object["deviceType"]?.stringValue
        platformArchitecture = object["platformArchitecture"]?.stringValue
        regionFormat = object["regionFormat"]?.stringValue
        pid = object["pid"]?.intValue
        isTestFlightApp = object["isTestFlightApp"]?.boolValue
        lowPowerModeEnabled = object["lowPowerModeEnabled"]?.boolValue
        exceptionType = object["exceptionType"]?.intValue
        exceptionCode = object["exceptionCode"]?.intValue
        signal = object["signal"]?.intValue
        terminationReason = object["terminationReason"]?.stringValue
        virtualMemoryRegionInfo = object["virtualMemoryRegionInfo"]?.stringValue
        objectiveCException = object["objectiveCexceptionReason"].flatMap(ObjectiveCExceptionReason.init(json:))
        hangDuration = object["hangDuration"]?.metricValue
        totalCPUTime = object["totalCPUTime"]?.metricValue
        totalSampledTime = object["totalSampledTime"]?.metricValue
        writesCaused = object["writesCaused"]?.metricValue
        launchDuration = object["launchDuration"]?.metricValue
        extra = object.filter { !Self.modeledKeys.contains($0.key) }
    }

    /// `"1.2.0 (42)"`.
    public var versionDescription: String? {
        switch (appVersion, appBuildVersion) {
        case let (version?, build?): "\(version) (\(build))"
        case let (version?, nil): version
        case let (nil, build?): "(\(build))"
        default: nil
        }
    }
}

/// The uncaught Objective-C exception behind a crash.
public struct ObjectiveCExceptionReason: Sendable, Hashable {
    public var exceptionName: String?
    public var composedMessage: String?
    public var className: String?
    public var exceptionType: String?
    public var formatString: String?
    public var arguments: [String]

    init?(json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        exceptionName = object["exceptionName"]?.stringValue
        composedMessage = object["composedMessage"]?.stringValue
        className = object["className"]?.stringValue
        exceptionType = object["exceptionType"]?.stringValue
        formatString = object["formatString"]?.stringValue
        arguments = object["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

/// Parses MetricKit's timestamps (`"2026-09-21 09:13:20"`, local time).
enum PayloadDate {
    static func parse(_ string: String) -> Date? {
        let parts = string.split(whereSeparator: { $0 == " " || $0 == "T" })
        guard parts.count >= 2 else { return nil }
        let date = parts[0].split(separator: "-").compactMap { Int($0) }
        let time = parts[1].split(separator: ":").compactMap { Int($0) }
        guard date.count == 3, time.count >= 2 else { return nil }
        var components = DateComponents()
        components.year = date[0]
        components.month = date[1]
        components.day = date[2]
        components.hour = time[0]
        components.minute = time[1]
        components.second = time.count > 2 ? time[2] : 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: components)
    }
}
