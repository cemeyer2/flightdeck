import Foundation
// A small JSON value type for the MCP server (MCPServer.swift). Codable structs would need a type per message and
// can't easily carry "any JSON" request ids and tool arguments, while `[String: Any]` from JSONSerialization isn't
// Sendable and loses key order. `JSON` is both: parsed from JSONSerialization's output, and serialised by hand so
// objects keep their insertion order. That order matters here: tool results put the summary first, and a reader
// (human or model) sees the most important part before the details.

/// A JSON value. Objects are ordered lists of key/value pairs (duplicate keys are never produced by this file).
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    /// Integers are kept apart from doubles so ids, PIDs and counts print without a fraction.
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.double(x), .double(y)): return x == y
        case let (.int(x), .double(y)), let (.double(y), .int(x)): return Double(x) == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        // Objects compare as maps: key order is presentation, not meaning.
        case let (.object(x), .object(y)):
            guard x.count == y.count else { return false }
            let dy = Dictionary(y, uniquingKeysWith: { a, _ in a })
            return x.allSatisfy { k, v in dy[k] == v }
        default: return false
        }
    }

    // MARK: Reading

    /// The value at `key` of an object (nil for other types or a missing key).
    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o.first { $0.0 == key }?.1 }
        return nil
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    /// An integer, also accepting an integral double (some clients send 5.0 for 5).
    public var int: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 9e15: return Int(d)
        default: return nil
        }
    }
    public var double: Double? {
        switch self { case .int(let i): return Double(i); case .double(let d): return d; default: return nil }
    }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var isObject: Bool { if case .object = self { return true }; return false }

    // MARK: Parsing

    public enum ParseError: Error { case invalid }

    /// Parses a JSON text (any top-level value). Throws `ParseError.invalid` for malformed input.
    public static func parse(_ data: Data) throws -> JSON {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { throw ParseError.invalid }
        return from(any)
    }

    /// Converts JSONSerialization's Foundation objects. NSNumber hides whether it was a boolean, an integer or a
    /// double, so the CoreFoundation type and the Objective-C type encoding are checked to tell them apart.
    static func from(_ any: Any) -> JSON {
        switch any {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let t = String(cString: n.objCType)
            if ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(t) { return .int(n.intValue) }
            return .double(n.doubleValue)
        case let a as [Any]: return .array(a.map(from))
        case let d as [String: Any]: return .object(d.keys.sorted().map { ($0, from(d[$0]!)) })
        default: return .null
        }
    }

    // MARK: Writing

    /// Compact UTF-8 serialisation, no whitespace, keys in insertion order.
    public var data: Data { Data(text.utf8) }

    public var text: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        // JSON has no NaN or infinity; such a value means "no number", so it is written as null rather than 0.
        case .double(let d):
            if !d.isFinite { out += "null" } else if d == d.rounded(), abs(d) < 1e15 { out += String(Int64(d)) } else { out += "\(d)" }
        case .string(let s): JSON.escape(s, into: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() { if i > 0 { out += "," }; v.write(into: &out) }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, (k, v)) in o.enumerated() {
                if i > 0 { out += "," }
                JSON.escape(k, into: &out); out += ":"; v.write(into: &out)
            }
            out += "}"
        }
    }

    /// RFC 8259 string escaping: quote, backslash and control characters. Everything else is written as UTF-8.
    static func escape(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        out += "\""
    }
}

// Literals make the tool code read like the JSON it produces. A dictionary literal keeps the order it was written in,
// and its values are optional: a nil value leaves the key out (used for "not applicable", never for "unmeasured",
// which is spelled out with `MCPFormat.unavailable`).
extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .int(v) }
    public init(floatLiteral v: Double) { self = .double(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral v: JSON...) { self = .array(v) }
    public init(dictionaryLiteral pairs: (String, JSON?)...) { self = .object(pairs.compactMap { k, v in v.map { (k, $0) } }) }

    /// An object from pairs, dropping nil values (for objects assembled in a loop).
    public static func object(dropping pairs: [(String, JSON?)]) -> JSON { .object(pairs.compactMap { k, v in v.map { (k, $0) } }) }
}

extension JSON {
    /// Convenience wrappers so call sites can write `.str(name)` for non-literal values.
    public static func str(_ s: String) -> JSON { .string(s) }
    public static func strings(_ a: [String]) -> JSON { .array(a.map(JSON.string)) }
}
