import Foundation

/// Tolerant, order-agnostic JSON representation. Every hook payload flows
/// through this type so unknown fields survive round-trips and renamed
/// fields (e.g. `tool_output` vs `tool_response`) can be probed by alias.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    /// Integers outside the Double-safe range (|v| > 2^53 - 1) are kept as
    /// Int64 so 64-bit values in user config files round-trip verbatim
    /// instead of being corrupted through Double. Numbers within the safe
    /// range always parse as `.number`, so equality with hand-built
    /// `.number(...)` values is unaffected.
    case integer(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self),
                  i < -9_007_199_254_740_991 || i > 9_007_199_254_740_991 {
            // Beyond Double's exact-integer range: keep the Int64 so the
            // value survives re-encoding bit-for-bit.
            self = .integer(i)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n):
            if n.truncatingRemainder(dividingBy: 1) == 0, n >= -9_007_199_254_740_991, n <= 9_007_199_254_740_991 {
                try container.encode(Int64(n))
            } else {
                try container.encode(n)
            }
        case .integer(let i): try container.encode(i)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

public extension JSONValue {
    init(parsing data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    init?(parsingLine line: String) {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self = value
    }

    func encodedData(pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        }
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    func encodedString(pretty: Bool = false) -> String {
        String(decoding: encodedData(pretty: pretty), as: UTF8.self)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    /// First present value among aliases (handles doc-vs-reality field renames).
    func first(of keys: [String]) -> JSONValue? {
        for k in keys {
            if let v = self[k], v != .null { return v }
        }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var double: Double? {
        switch self {
        case .number(let n): return n
        case .integer(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var int: Int? {
        if case .integer(let i) = self { return Int(exactly: i) }
        guard let d = double else { return nil }
        return Int(d)
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var isNull: Bool { self == .null }
}
