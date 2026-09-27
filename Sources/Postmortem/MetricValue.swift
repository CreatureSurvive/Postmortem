import Foundation

/// A value from a MetricKit payload, which reports measurements as strings
/// such as `"250 sec"`, `"2500 ms"`, `"310000 kB"` or `"4 ms per s"`.
public struct MetricValue: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The numeric value, or `nil` if the string couldn't be parsed.
    public var value: Double?
    /// The unit as written, such as `"sec"`, `"kB"` or `"ms per s"`.
    public var unit: String?
    /// The original string.
    public var raw: String

    public init(value: Double?, unit: String?, raw: String) {
        self.value = value
        self.unit = unit
        self.raw = raw
    }

    /// Parses a measurement string. Grouping separators (`2,000 ms`) are
    /// accepted.
    public init(_ raw: String) {
        self.raw = raw
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var numberEnd = trimmed.startIndex
        for index in trimmed.indices {
            let character = trimmed[index]
            if character.isNumber || character == "." || character == "," || character == "-" || character == "+" || character == "e" && index != trimmed.startIndex && trimmed[trimmed.index(before: index)].isNumber {
                numberEnd = trimmed.index(after: index)
            } else {
                break
            }
        }
        let numberPart = String(trimmed[..<numberEnd])
        let unitPart = trimmed[numberEnd...].trimmingCharacters(in: .whitespaces)
        value = Self.parseNumber(numberPart)
        unit = unitPart.isEmpty ? nil : unitPart
    }

    /// Treats commas followed by exactly three digits as grouping, other
    /// commas as a decimal separator.
    static func parseNumber(_ string: String) -> Double? {
        guard !string.isEmpty else { return nil }
        let groups = string.split(separator: ",", omittingEmptySubsequences: false)
        let normalized: String
        if groups.count > 1, groups.dropFirst().allSatisfy({ $0.count == 3 || $0.contains(".") && $0.prefix(while: { $0 != "." }).count == 3 }) {
            normalized = groups.joined()
        } else {
            normalized = string.replacingOccurrences(of: ",", with: ".")
        }
        return Double(normalized)
    }

    public var description: String { raw }

    /// The value in seconds, for durations (`ms`, `sec`, `min`, `hr`, …).
    public var seconds: Double? {
        guard let value, let unit = unit?.lowercased() else { return nil }
        switch unit {
        case "ns": return value / 1_000_000_000
        case "µs", "us", "μs": return value / 1_000_000
        case "ms": return value / 1000
        case "s", "sec", "secs", "second", "seconds": return value
        case "min", "mins", "minute", "minutes": return value * 60
        case "hr", "hrs", "h", "hour", "hours": return value * 3600
        default: return nil
        }
    }

    /// The value in bytes, for storage sizes (`byte`, `kB`, `MB`, …).
    ///
    /// MetricKit uses decimal units (`kB` = 1000 bytes), following
    /// `UnitInformationStorage`.
    public var bytes: Double? {
        guard let value, let unit else { return nil }
        switch unit {
        case "byte", "bytes", "B": return value
        case "kB", "KB": return value * 1e3
        case "MB": return value * 1e6
        case "GB": return value * 1e9
        case "TB": return value * 1e12
        case "KiB": return value * 1024
        case "MiB": return value * 1_048_576
        case "GiB": return value * 1_073_741_824
        default: return nil
        }
    }

    /// A compact, human-readable form: durations and sizes are converted to
    /// the most natural unit; other values are returned as written.
    public var formatted: String {
        if let seconds {
            if seconds < 1 { return "\(Self.trim(seconds * 1000)) ms" }
            if seconds < 120 { return "\(Self.trim(seconds)) s" }
            if seconds < 7200 { return "\(Self.trim(seconds / 60)) min" }
            return "\(Self.trim(seconds / 3600)) h"
        }
        if let bytes {
            return ByteCountFormatter.string(fromByteCount: Int64(clamping: Int(bytes.rounded(.towardZero).clamped(to: -9e18...9e18))), countStyle: .memory)
        }
        return raw
    }

    static func trim(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
