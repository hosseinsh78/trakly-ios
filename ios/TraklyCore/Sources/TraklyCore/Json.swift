import Foundation

/// A strict JSON reader and writer (RFC 8259, the grammar of `JSON.parse`), the one JSON implementation of the app
/// (docs/specs/phase10-apps-and-stores.md §B3: the bridge, the basket and capture files, the reader's summaries). Pure.
///
/// `JSONSerialization` answers `NSNumber` for both numbers and booleans on Apple platforms (so `1` passes a `Bool`
/// check) and differs from swift-corelibs-foundation on Linux; the shared fixtures could not prove the device's
/// behaviour with it. This is the port of Android's `core/Json.kt`: the same code runs in the Linux tests and on the
/// phone. Objects keep their key order; the last of duplicate keys wins, in the position of the first, as in
/// `JSON.parse`. Every number is a `Double`, as in JavaScript.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    /// The number as an integer when it is one (finite, no fraction), else nil.
    public var intValue: Int? {
        guard case let .number(value) = self, value.isFinite, value == value.rounded(), abs(value) < 9.0e15 else { return nil }
        return Int(value)
    }

    public var objectValue: JSONObject? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The strings of an array (nil when it is not an array of strings only).
    public var stringList: [String]? {
        guard case let .array(items) = self else { return nil }
        var out: [String] = []
        for item in items {
            guard case let .string(text) = item else { return nil }
            out.append(text)
        }
        return out
    }
}

/// A JSON object with its key order (insertion order, as `JSON.parse` and `JSON.stringify`).
public struct JSONObject: Equatable, Sendable, Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs {
            self[key] = value
        }
    }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil {
                    keys.append(key)
                }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public func has(_ key: String) -> Bool { storage[key] != nil }

    public var count: Int { keys.count }

    public var isEmpty: Bool { keys.isEmpty }

    public func string(_ key: String) -> String? { storage[key]?.stringValue }

    public func bool(_ key: String) -> Bool? { storage[key]?.boolValue }

    public func number(_ key: String) -> Double? { storage[key]?.doubleValue }

    public func object(_ key: String) -> JSONObject? { storage[key]?.objectValue }

    public func array(_ key: String) -> [JSONValue]? { storage[key]?.arrayValue }

    /// The object without `drop`'s keys.
    public func without(_ drop: Set<String>) -> JSONObject {
        var out = JSONObject()
        for key in keys where !drop.contains(key) {
            out[key] = storage[key]
        }
        return out
    }

    /// Every pair of `other` set on a copy (`Object.assign`).
    public func merging(_ other: JSONObject) -> JSONObject {
        var out = self
        for (key, value) in other {
            out[key] = value
        }
        return out
    }

    public func makeIterator() -> AnyIterator<(String, JSONValue)> {
        var index = 0
        let keys = self.keys
        let storage = self.storage
        return AnyIterator {
            guard index < keys.count else { return nil }
            let key = keys[index]
            index += 1
            return (key, storage[key] ?? .null)
        }
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.keys == rhs.keys && lhs.storage == rhs.storage
    }
}

public enum Json {
    public struct SyntaxError: Error, Equatable {
        public let message: String
    }

    static let maxDepth = 64

    /// Parses `text`, or nil when it is not exactly one JSON value (whitespace around it allowed).
    public static func parseOrNil(_ text: String) -> JSONValue? {
        try? parse(text)
    }

    /// Parses `text`; throws for anything `JSON.parse` would refuse.
    public static func parse(_ text: String) throws -> JSONValue {
        var reader = Reader(units: Array(text.utf16))
        reader.skipWhitespace()
        let value = try reader.value(depth: 0)
        reader.skipWhitespace()
        if !reader.atEnd {
            throw SyntaxError(message: "trailing characters at \(reader.position)")
        }
        return value
    }

    /// An object from its text, or nil.
    public static func object(_ text: String) -> JSONObject? {
        parseOrNil(text)?.objectValue
    }

    /// One value as JSON text (objects keep their order; numbers as JavaScript prints them).
    public static func write(_ value: JSONValue) -> String {
        var out = ""
        append(&out, value)
        return out
    }

    public static func write(_ object: JSONObject) -> String {
        write(.object(object))
    }

    public static func quote(_ text: String) -> String {
        var out = ""
        appendString(&out, text)
        return out
    }

    /// UTF-8 bytes of a string (`utf8Bytes()` of messages.ts; Swift strings hold no lone surrogate).
    public static func utf8Bytes(_ text: String) -> Int {
        text.utf8.count
    }

    // MARK: - reader

    private struct Reader {
        let units: [UInt16]
        var position = 0

        init(units: [UInt16]) {
            self.units = units
        }

        var atEnd: Bool { position >= units.count }

        func peek() -> UInt16 { position < units.count ? units[position] : 0 }

        mutating func skipWhitespace() {
            while position < units.count {
                switch units[position] {
                case 0x20, 0x09, 0x0A, 0x0D: position += 1
                default: return
                }
            }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            if depth > Json.maxDepth {
                throw SyntaxError(message: "too deep")
            }
            if atEnd {
                throw SyntaxError(message: "unexpected end")
            }
            switch units[position] {
            case 0x7B: return try objectValue(depth: depth) // {
            case 0x5B: return try arrayValue(depth: depth) // [
            case 0x22: return .string(try string()) // "
            case 0x74: return try literal("true", .bool(true))
            case 0x66: return try literal("false", .bool(false))
            case 0x6E: return try literal("null", .null)
            case 0x2D, 0x30...0x39: return .number(try number())
            default: throw SyntaxError(message: "unexpected character at \(position)")
            }
        }

        private mutating func literal(_ word: String, _ value: JSONValue) throws -> JSONValue {
            let letters = Array(word.utf16)
            guard position + letters.count <= units.count, Array(units[position ..< position + letters.count]) == letters else {
                throw SyntaxError(message: "bad literal at \(position)")
            }
            position += letters.count
            return value
        }

        private mutating func objectValue(depth: Int) throws -> JSONValue {
            position += 1
            var result = JSONObject()
            skipWhitespace()
            if peek() == 0x7D {
                position += 1
                return .object(result)
            }
            while true {
                skipWhitespace()
                guard peek() == 0x22 else {
                    throw SyntaxError(message: "expected a key at \(position)")
                }
                let key = try string()
                skipWhitespace()
                guard peek() == 0x3A else {
                    throw SyntaxError(message: "expected : at \(position)")
                }
                position += 1
                skipWhitespace()
                let item = try value(depth: depth + 1)
                result[key] = item
                skipWhitespace()
                switch peek() {
                case 0x2C: position += 1
                case 0x7D:
                    position += 1
                    return .object(result)
                default: throw SyntaxError(message: "expected , or } at \(position)")
                }
            }
        }

        private mutating func arrayValue(depth: Int) throws -> JSONValue {
            position += 1
            var result: [JSONValue] = []
            skipWhitespace()
            if peek() == 0x5D {
                position += 1
                return .array(result)
            }
            while true {
                skipWhitespace()
                result.append(try value(depth: depth + 1))
                skipWhitespace()
                switch peek() {
                case 0x2C: position += 1
                case 0x5D:
                    position += 1
                    return .array(result)
                default: throw SyntaxError(message: "expected , or ] at \(position)")
                }
            }
        }

        private static func hexValue(_ unit: UInt16) -> UInt16? {
            switch unit {
            case 0x30...0x39: return unit - 0x30
            case 0x41...0x46: return unit - 0x41 + 10
            case 0x61...0x66: return unit - 0x61 + 10
            default: return nil
            }
        }

        private mutating func string() throws -> String {
            position += 1
            var out: [UInt16] = []
            while true {
                guard position < units.count else {
                    throw SyntaxError(message: "unterminated string")
                }
                let unit = units[position]
                if unit == 0x22 {
                    position += 1
                    return String(decoding: out, as: UTF16.self)
                }
                if unit == 0x5C {
                    guard position + 1 < units.count else {
                        throw SyntaxError(message: "bad escape")
                    }
                    switch units[position + 1] {
                    case 0x22: out.append(0x22)
                    case 0x5C: out.append(0x5C)
                    case 0x2F: out.append(0x2F)
                    case 0x62: out.append(0x08)
                    case 0x66: out.append(0x0C)
                    case 0x6E: out.append(0x0A)
                    case 0x72: out.append(0x0D)
                    case 0x74: out.append(0x09)
                    case 0x75:
                        guard position + 6 <= units.count else {
                            throw SyntaxError(message: "bad unicode escape")
                        }
                        var code: UInt16 = 0
                        for offset in 2 ..< 6 {
                            guard let digit = Reader.hexValue(units[position + offset]) else {
                                throw SyntaxError(message: "bad unicode escape")
                            }
                            code = code * 16 + digit
                        }
                        out.append(code)
                        position += 4
                    default:
                        throw SyntaxError(message: "bad escape")
                    }
                    position += 2
                    continue
                }
                if unit < 0x20 {
                    throw SyntaxError(message: "control character in a string")
                }
                out.append(unit)
                position += 1
            }
        }

        private func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

        private mutating func number() throws -> Double {
            let start = position
            if peek() == 0x2D {
                position += 1
            }
            if peek() == 0x30 {
                position += 1
            } else if peek() >= 0x31 && peek() <= 0x39 {
                while isDigit(peek()) { position += 1 }
            } else {
                throw SyntaxError(message: "bad number at \(start)")
            }
            if peek() == 0x2E {
                position += 1
                guard isDigit(peek()) else {
                    throw SyntaxError(message: "bad fraction at \(start)")
                }
                while isDigit(peek()) { position += 1 }
            }
            if peek() == 0x65 || peek() == 0x45 {
                position += 1
                if peek() == 0x2B || peek() == 0x2D {
                    position += 1
                }
                guard isDigit(peek()) else {
                    throw SyntaxError(message: "bad exponent at \(start)")
                }
                while isDigit(peek()) { position += 1 }
            }
            let text = String(decoding: units[start ..< position], as: UTF16.self)
            guard let value = Double(text) else {
                throw SyntaxError(message: "bad number at \(start)")
            }
            return value
        }
    }

    // MARK: - writer

    private static func append(_ out: inout String, _ value: JSONValue) {
        switch value {
        case .null: out += "null"
        case let .bool(flag): out += flag ? "true" : "false"
        case let .number(number): appendNumber(&out, number)
        case let .string(text): appendString(&out, text)
        case let .array(items):
            out += "["
            var first = true
            for item in items {
                if !first { out += "," }
                first = false
                append(&out, item)
            }
            out += "]"
        case let .object(object):
            out += "{"
            var first = true
            for (key, item) in object {
                if !first { out += "," }
                first = false
                appendString(&out, key)
                out += ":"
                append(&out, item)
            }
            out += "}"
        }
    }

    private static func appendNumber(_ out: inout String, _ number: Double) {
        if number.isNaN || number.isInfinite {
            out += "null"
        } else if number == number.rounded() && abs(number) < 1e15 {
            out += String(Int64(number))
        } else {
            out += "\(number)"
        }
    }

    private static let hex: [Character] = Array("0123456789abcdef")

    private static func appendString(_ out: inout String, _ text: String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                let code = scalar.value
                if code < 0x20 || code == 0x2028 || code == 0x2029 {
                    out += "\\u"
                    out.append(hex[Int((code >> 12) & 0xF)])
                    out.append(hex[Int((code >> 8) & 0xF)])
                    out.append(hex[Int((code >> 4) & 0xF)])
                    out.append(hex[Int(code & 0xF)])
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

// MARK: - literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}

extension JSONValue {
    /// A string or JSON null.
    public static func optional(_ text: String?) -> JSONValue {
        text.map { .string($0) } ?? .null
    }

    public static func int(_ value: Int) -> JSONValue { .number(Double(value)) }

    public static func strings(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }
}
