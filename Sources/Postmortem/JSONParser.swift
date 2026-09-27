import Foundation

/// A JSON parser with no nesting limit.
///
/// MetricKit nests each stack frame two levels inside its caller, so a
/// 300-frame crash is 600 levels deep. Foundation's parser gives up at 512
/// levels, which would lose exactly the stack-overflow crashes you most want
/// to see. This parser uses an explicit stack instead of recursion.
enum JSONParser {
    static let maximumDepth = 100_000

    static func parse(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { buffer in
            var parser = Parser(bytes: buffer.bindMemory(to: UInt8.self))
            return try parser.parseDocument()
        }
    }

    private enum Container {
        case array([JSONValue])
        case object([String: JSONValue], pendingKey: String?)
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        mutating func parseDocument() throws -> JSONValue {
            var stack: [Container] = []
            var result: JSONValue?
            defer {
                // After an error, free partial containers without recursion.
                while let container = stack.popLast() {
                    switch container {
                    case .array(let items): JSONValue.release(.array(items))
                    case .object(let members, _): JSONValue.release(.object(members))
                    }
                }
            }

            func fail(_ message: String) -> PostmortemError {
                .invalidPayload("\(message) at byte \(index)")
            }

            skipWhitespace()
            while true {
                // Expect a value (or a closing bracket for an empty container).
                var value: JSONValue?
                guard index < bytes.count else { throw fail("unexpected end of JSON") }
                switch bytes[index] {
                case UInt8(ascii: "{"):
                    index += 1
                    skipWhitespace()
                    if peek(UInt8(ascii: "}")) {
                        index += 1
                        value = .object([:])
                    } else {
                        guard stack.count < JSONParser.maximumDepth else { throw fail("nesting too deep") }
                        let key = try parseKey()
                        stack.append(.object([:], pendingKey: key))
                        skipWhitespace()
                        continue
                    }
                case UInt8(ascii: "["):
                    index += 1
                    skipWhitespace()
                    if peek(UInt8(ascii: "]")) {
                        index += 1
                        value = .array([])
                    } else {
                        guard stack.count < JSONParser.maximumDepth else { throw fail("nesting too deep") }
                        stack.append(.array([]))
                        continue
                    }
                case UInt8(ascii: "\""):
                    value = .string(try parseString())
                case UInt8(ascii: "t"):
                    try expectLiteral("true")
                    value = .bool(true)
                case UInt8(ascii: "f"):
                    try expectLiteral("false")
                    value = .bool(false)
                case UInt8(ascii: "n"):
                    try expectLiteral("null")
                    value = .null
                default:
                    value = .number(try parseNumber())
                }

                // Attach the completed value, closing containers as needed.
                var completed = value!
                while true {
                    skipWhitespace()
                    guard var top = stack.popLast() else {
                        result = completed
                        break
                    }
                    switch top {
                    case .array(var items):
                        items.append(completed)
                        if consume(UInt8(ascii: ",")) {
                            stack.append(.array(items))
                            skipWhitespace()
                            break
                        } else if consume(UInt8(ascii: "]")) {
                            completed = .array(items)
                            continue
                        } else {
                            throw fail("expected , or ]")
                        }
                    case .object(var members, let key):
                        members[key ?? ""] = completed
                        if consume(UInt8(ascii: ",")) {
                            skipWhitespace()
                            let nextKey = try parseKey()
                            top = .object(members, pendingKey: nextKey)
                            stack.append(top)
                            skipWhitespace()
                            break
                        } else if consume(UInt8(ascii: "}")) {
                            completed = .object(members)
                            continue
                        } else {
                            throw fail("expected , or }")
                        }
                    }
                    break
                }
                if let result {
                    skipWhitespace()
                    guard index == bytes.count else { throw fail("trailing characters") }
                    return result
                }
            }
        }

        mutating func parseKey() throws -> String {
            guard peek(UInt8(ascii: "\"")) else { throw PostmortemError.invalidPayload("expected a key at byte \(index)") }
            let key = try parseString()
            skipWhitespace()
            guard consume(UInt8(ascii: ":")) else { throw PostmortemError.invalidPayload("expected : at byte \(index)") }
            skipWhitespace()
            return key
        }

        mutating func parseString() throws -> String {
            index += 1 // opening quote
            var scalars = String.UnicodeScalarView()
            var runStart = index
            func flushRun() {
                if runStart < index {
                    scalars.append(contentsOf: String(decoding: UnsafeBufferPointer(rebasing: bytes[runStart..<index]), as: UTF8.self).unicodeScalars)
                }
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    flushRun()
                    index += 1
                    return String(scalars)
                }
                if byte == UInt8(ascii: "\\") {
                    flushRun()
                    index += 1
                    guard index < bytes.count else { break }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        var code = try parseHex4()
                        if (0xD800...0xDBFF).contains(code), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            let low = try parseHex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            }
                        }
                        scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default:
                        throw PostmortemError.invalidPayload("invalid escape at byte \(index)")
                    }
                    runStart = index
                    continue
                }
                index += 1
            }
            throw PostmortemError.invalidPayload("unterminated string")
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw PostmortemError.invalidPayload("truncated \\u escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw PostmortemError.invalidPayload("invalid \\u escape at byte \(index)")
                }
                value = value << 4 | digit
                index += 1
            }
            return value
        }

        mutating func parseNumber() throws -> Double {
            let start = index
            while index < bytes.count {
                let byte = bytes[index]
                let isNumberByte = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
                    || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
                guard isNumberByte else { break }
                index += 1
            }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
            guard !text.isEmpty, let value = Double(text) else { throw PostmortemError.invalidPayload("invalid value at byte \(start)") }
            return value
        }

        mutating func expectLiteral(_ literal: StaticString) throws {
            let length = literal.utf8CodeUnitCount
            guard index + length <= bytes.count else { throw PostmortemError.invalidPayload("invalid literal at byte \(index)") }
            for offset in 0..<length where bytes[index + offset] != literal.utf8Start[offset] {
                throw PostmortemError.invalidPayload("invalid literal at byte \(index)")
            }
            index += length
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        func peek(_ byte: UInt8) -> Bool {
            index < bytes.count && bytes[index] == byte
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard peek(byte) else { return false }
            index += 1
            return true
        }
    }
}

extension JSONValue {
    /// Canonical JSON (sorted keys), written without recursion. Used to
    /// identify identical diagnostics.
    func canonicalData() -> Data {
        enum Work { case value(JSONValue), text(String) }
        var output = ""
        var stack: [Work] = [.value(self)]
        while let item = stack.popLast() {
            switch item {
            case .text(let text):
                output += text
            case .value(let value):
                switch value {
                case .null: output += "null"
                case .bool(let bool): output += bool ? "true" : "false"
                case .number(let number): output += number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
                case .string(let string): output += Self.quoted(string)
                case .array(let items):
                    output += "["
                    stack.append(.text("]"))
                    for (offset, element) in items.enumerated().reversed() {
                        stack.append(.value(element))
                        if offset > 0 { stack.append(.text(",")) }
                    }
                case .object(let members):
                    output += "{"
                    stack.append(.text("}"))
                    let sorted = members.sorted { $0.key < $1.key }
                    for (offset, member) in sorted.enumerated().reversed() {
                        stack.append(.value(member.value))
                        stack.append(.text(Self.quoted(member.key) + ":"))
                        if offset > 0 { stack.append(.text(",")) }
                    }
                }
            }
        }
        return Data(output.utf8)
    }

    static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
