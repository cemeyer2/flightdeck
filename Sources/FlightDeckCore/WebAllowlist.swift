import Foundation
import Network
import Darwin
// Web dashboard, part 1: IP addresses, prefixes and the "Allowed addresses" text from Settings. Everything here is
// pure parsing. IPv4-mapped IPv6 (::ffff:a.b.c.d) is folded into IPv4 so one entry matches both forms a socket can
// report; no other translation range (64:ff9b::/96, 6to4) is, since those are different hosts. Zone IDs ("%en0")
// are refused: an entry names addresses, not interfaces.

/// An IPv4 (4 bytes) or IPv6 (16 bytes) address.
public struct WebIP: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]
    public var isV4: Bool { bytes.count == 4 }

    init(bytes: [UInt8]) { self.bytes = Self.unmapped(bytes) }

    /// Parses a numeric address ("192.168.1.5", "fd12::1", "::ffff:10.0.0.1"); nil for names and zone IDs.
    public init?(_ text: String) {
        guard let b = Self.rawBytes(text) else { return nil }
        self.init(bytes: b)
    }

    /// The address of a socket endpoint's host; nil for names.
    public init?(_ host: NWEndpoint.Host) {
        switch host {
        case .ipv4(let a): self.init(bytes: Array(a.rawValue))
        case .ipv6(let a): self.init(bytes: Array(a.rawValue))
        default: return nil
        }
    }

    public static let loopbackV4 = WebIP(bytes: [127, 0, 0, 1])
    public static let loopbackV6 = WebIP(bytes: Array(repeating: 0, count: 15) + [1])
    /// 127/8 or ::1.
    public var isLoopback: Bool { isV4 ? bytes[0] == 127 : self == Self.loopbackV6 }

    public var description: String {
        var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        bytes.withUnsafeBytes { p in _ = inet_ntop(isV4 ? AF_INET : AF_INET6, p.baseAddress, &out, socklen_t(out.count)) }
        return String(cString: out)
    }

    /// inet_pton's bytes, without folding mapped addresses (WebPrefix needs them raw to adjust the length).
    static func rawBytes(_ text: String) -> [UInt8]? {
        guard !text.contains("%"), !text.isEmpty else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    static func isMapped(_ b: [UInt8]) -> Bool {
        b.count == 16 && b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff
    }
    static func unmapped(_ b: [UInt8]) -> [UInt8] { isMapped(b) ? Array(b[12...]) : b }
}

/// An address range: a masked network address and its prefix length. A bare address is a /32 or /128.
public struct WebPrefix: Hashable, Sendable, CustomStringConvertible {
    public let address: WebIP
    public let length: Int

    /// Masks host bits ("10.1.2.3", 8 → 10.0.0.0/8). The length is clamped to the family's width.
    public init(address: WebIP, length: Int) {
        let bits = address.bytes.count * 8, len = max(0, min(length, bits))
        self.address = WebIP(bytes: Self.mask(address.bytes, len)); self.length = len
    }

    private init(exact address: WebIP, length: Int) { self.address = address; self.length = length }

    /// "addr" or "addr/len"; nil when either part is malformed or the length is too long for the family.
    public init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let raw = WebIP.rawBytes(parts[0]) else { return nil }
        var len = raw.count * 8
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isNumber), let n = Int(parts[1]),
                  n <= raw.count * 8 else { return nil }
            len = n
        }
        // ::ffff:10.0.0.0/104 is 10.0.0.0/8; a mapped address with a shorter length spans more than IPv4, so stays IPv6.
        if WebIP.isMapped(raw) && len >= 96 {
            self.init(address: WebIP(bytes: Array(raw[12...])), length: len - 96)
        } else {
            self.init(exact: WebIP(rawUnfolded: Self.mask(raw, len)), length: len)
        }
    }

    public static let tailnetV4 = WebPrefix("100.64.0.0/10")!
    public static let tailnetV6 = WebPrefix("fd7a:115c:a1e0::/48")!
    /// Inside Tailscale's address ranges (CGNAT space is only tailnet when it arrives over Tailscale; see WebAccess).
    public static func isTailnet(_ ip: WebIP) -> Bool { tailnetV4.contains(ip) || tailnetV6.contains(ip) }

    public var isHost: Bool { length == address.bytes.count * 8 }

    /// False across families.
    public func contains(_ ip: WebIP) -> Bool {
        ip.bytes.count == address.bytes.count && Self.mask(ip.bytes, length) == address.bytes
    }
    public func contains(_ p: WebPrefix) -> Bool { p.length >= length && contains(p.address) }

    public var description: String { isHost ? address.description : "\(address)/\(length)" }

    static func mask(_ b: [UInt8], _ len: Int) -> [UInt8] {
        b.enumerated().map { i, byte in
            let keep = max(0, min(8, len - i * 8))
            return keep == 8 ? byte : byte & UInt8(truncatingIfNeeded: 0xff << (8 - keep))
        }
    }
}

extension WebIP {
    /// A 16-byte address kept as IPv6 even though it is in the mapped range (a mapped prefix shorter than /96).
    init(rawUnfolded b: [UInt8]) { self.bytes = b }
}

/// The parsed "Allowed addresses" setting. Empty means "the local network" (see WebAccess).
public struct WebAllowlist: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Hashable {
        /// As typed.
        public var text: String
        public var prefix: WebPrefix
        /// 1-based, among the non-empty tokens.
        public var position: Int
        /// The normalized form differs from what was typed (host bits masked, a mapped address folded): Settings
        /// shows it next to the entry.
        public var normalizedChanged: Bool
    }
    public struct Invalid: Sendable, Equatable, Hashable {
        public var position: Int
        public var text: String
        public var reason: String
    }
    public private(set) var entries: [Entry] = []
    public private(set) var invalid: [Invalid] = []
    /// Nothing typed at all (invalid entries count as something).
    public var isEmpty: Bool { entries.isEmpty && invalid.isEmpty }

    /// Splits on commas, newlines and whitespace, skips empty tokens and drops repeats of an earlier entry.
    public static func parse(_ raw: String) -> WebAllowlist {
        var out = WebAllowlist(), seen = Set<WebPrefix>()
        let tokens = raw.split { $0 == "," || $0.isWhitespace || $0.isNewline }.map(String.init)
        for (i, t) in tokens.enumerated() {
            if let p = WebPrefix(t) {
                guard seen.insert(p).inserted else { continue }
                out.entries.append(Entry(text: t, prefix: p, position: i + 1, normalizedChanged: p.description != t))
            } else {
                out.invalid.append(Invalid(position: i + 1, text: t, reason: reason(t)))
            }
        }
        return out
    }

    static func reason(_ t: String) -> String {
        if t.contains("%") { return "Interface names (%…) aren't allowed; enter the address or range alone" }
        if let slash = t.firstIndex(of: "/"), WebIP.rawBytes(String(t[..<slash])) != nil {
            return "The length after / must be 0–32 for IPv4 or 0–128 for IPv6"
        }
        return "Not an IP address or range"
    }

    public func contains(_ ip: WebIP) -> Bool { entries.contains { $0.prefix.contains(ip) } }
}
