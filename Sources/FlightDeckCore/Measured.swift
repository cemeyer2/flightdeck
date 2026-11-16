import Foundation
// The core "never invent zeros" type. Samplers return `Measured` for any metric macOS may refuse to give us
// (no root, missing private symbol, sensor absent), so the UI can show "—" and the analyzer can skip it
// instead of treating a missing reading as an idle machine.

/// A value that is either measured, or explicitly unavailable (never a fake zero).
public enum Measured<T: Codable & Sendable>: Codable, Sendable {
    case value(T)
    /// Not measured this time. The string is a short human-readable reason (e.g. "warming up", "not reported") for tooltips/logs.
    case unavailable(String)

    /// The measured value, or nil when unavailable. Callers should treat nil as "unknown", not as 0.
    public var value: T? { if case .value(let v) = self { return v }; return nil }
    public var isAvailable: Bool { value != nil }
    /// Transforms a measured value (e.g. a unit conversion) while carrying an unavailable reason through untouched.
    public func map<U>(_ f: (T) -> U) -> Measured<U> {
        switch self {
        case .value(let v): return .value(f(v))
        case .unavailable(let r): return .unavailable(r)
        }
    }
}

public extension Measured where T == Double {
    /// Formats with `f`, or returns an em dash for unavailable values so the UI never prints a misleading "0".
    func formatted(_ f: (Double) -> String) -> String { value.map(f) ?? "—" }
}
