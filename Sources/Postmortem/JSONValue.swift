import Foundation

/// Any JSON value. Payload sections that aren't modeled are kept in this
/// form so nothing MetricKit reports is lost.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let number): number
        case .string(let string): Double(string)
        default: nil
        }
    }

    public var intValue: Int? {
        guard let double = doubleValue, double.isFinite, let int = Int(exactly: double.rounded()) else { return nil }
        return int
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let bool): bool
        case .number(let number): number != 0
        default: nil
        }
    }

    /// A measurement string such as `"250 sec"` parsed into a value.
    public var metricValue: MetricValue? {
        switch self {
        case .string(let string): MetricValue(string)
        case .number(let number): MetricValue(value: number, unit: nil, raw: String(number))
        default: nil
        }
    }

    /// Frees a value with a loop instead of recursive deallocation, which
    /// can overflow a thread's stack for deeply nested values such as the
    /// call stack tree of a runaway recursion.
    static func release(_ value: consuming JSONValue) {
        var pending = [consume value]
        while let next = pending.popLast() {
            // Children stay owned by `pending` while their container is
            // freed, so each step frees at most one level.
            switch next {
            case .array(let items): pending.append(contentsOf: items)
            case .object(let members): pending.append(contentsOf: members.values)
            default: break
            }
        }
    }

    /// Decodes this value as `type`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}
