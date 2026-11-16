import Foundation

/// A value that is either measured, or explicitly unavailable (never a fake zero).
public enum Measured<T: Codable & Sendable>: Codable, Sendable {
    case value(T)
    case unavailable(String)

    public var value: T? { if case .value(let v) = self { return v }; return nil }
    public var isAvailable: Bool { value != nil }
    public func map<U>(_ f: (T) -> U) -> Measured<U> {
        switch self {
        case .value(let v): return .value(f(v))
        case .unavailable(let r): return .unavailable(r)
        }
    }
}

public extension Measured where T == Double {
    func formatted(_ f: (Double) -> String) -> String { value.map(f) ?? "—" }
}
