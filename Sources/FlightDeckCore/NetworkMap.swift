import Foundation

// Network map, part 1: the building blocks. MAC address normalisation and the randomized-address rule, the OUI vendor
// lookup, IPv4 subnet arithmetic, and parsers for `arp -an`, `ndp -an` and `traceroute -n`. Everything here is pure
// so it can be unit-tested with captured output; the live collectors are in NetworkDiscovery.swift, merging and
// identification in NetworkInventory.swift, and the map's topology in NetworkTopology.swift.

/// MAC address helpers. MACs are kept in one canonical form: lowercase, colon-separated, two digits per octet.
public enum MAC {
    /// "b8:27:eb:f7:7:69" (arp and ndp drop leading zeros) → "b8:27:eb:f7:07:69". Also accepts "-" separators.
    /// nil for anything that isn't six hex octets, such as "(incomplete)".
    public static func normalize(_ s: String) -> String? {
        let parts = s.lowercased().split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var out: [String] = []
        for p in parts {
            guard (1...2).contains(p.count), let v = UInt8(p, radix: 16) else { return nil }
            out.append(String(format: "%02x", v))
        }
        return out.joined(separator: ":")
    }

    /// The first octet's value, or nil for a malformed address.
    static func firstOctet(_ mac: String) -> UInt8? { mac.split(separator: ":").first.flatMap { UInt8($0, radix: 16) } }

    /// True when the "locally administered" bit (0x02 of the first octet) is set, i.e. the second hex digit is 2, 6, A
    /// or E. Such addresses aren't assigned by a manufacturer: phones and computers use them as per-network private
    /// (randomized) Wi-Fi addresses, so their first three octets say nothing about who made the device.
    public static func isLocallyAdministered(_ mac: String) -> Bool { (firstOctet(mac) ?? 0) & 0x02 != 0 }

    /// Group (multicast or broadcast) addresses have the low bit of the first octet set; they're never a device.
    public static func isGroup(_ mac: String) -> Bool { (firstOctet(mac) ?? 0) & 0x01 != 0 }
}

/// What a MAC address says about the device's manufacturer.
public enum Vendor: Hashable, Sendable, Codable {
    /// The OUI (first three octets) is in the bundled table.
    case known(String)
    /// A locally administered address (usually a randomized private Wi-Fi address): there is no vendor to look up.
    case privateAddress
    /// A manufacturer-assigned address whose OUI isn't in the bundled table of common vendors.
    case unlisted
    /// No MAC address is known (e.g. a device seen only through Bonjour over a VPN, or not yet in the ARP table).
    case noMAC

    public var name: String? { if case .known(let n) = self { return n }; return nil }
    /// Human-readable, including the reason when the vendor is unknown.
    public var label: String {
        switch self {
        case .known(let n): n
        case .privateAddress: "private address (randomized MAC, no vendor)"
        case .unlisted: "unknown vendor (not in the bundled OUI table)"
        case .noMAC: "unknown (no MAC address seen)"
        }
    }
}

/// MAC prefix (OUI) → vendor, from the generated table in OUIVendors.swift.
public enum OUI {
    /// First three octets as a 24-bit number → index into `names`. Built once, on first use (~13,000 entries).
    private static let table: (index: [UInt32: Int], names: [String]) = {
        var index: [UInt32: Int] = [:], names: [String] = []
        index.reserveCapacity(14_000)
        for (i, (name, prefixes)) in packed.enumerated() {
            names.append(name)
            for p in prefixes.split(separator: " ") { if let v = UInt32(p, radix: 16) { index[v] = i } }
        }
        return (index, names)
    }()

    /// Number of prefixes in the bundled table (for the view's footnote and tests).
    public static var count: Int { table.index.count }

    /// Vendor for a MAC in any form `MAC.normalize` accepts. Randomized addresses are never looked up: a private
    /// address that happens to collide with a real OUI would otherwise name the wrong manufacturer.
    public static func lookup(_ mac: String?) -> Vendor {
        guard let mac, let m = MAC.normalize(mac) else { return .noMAC }
        if MAC.isLocallyAdministered(m) { return .privateAddress }
        let hex = m.split(separator: ":").prefix(3).joined()
        guard let v = UInt32(hex, radix: 16), let i = table.index[v] else { return .unlisted }
        return .known(table.names[i])
    }
}

/// IPv4 address arithmetic on 32-bit values (host byte order).
public enum IPv4 {
    public static func parse(_ s: String) -> UInt32? {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return nil }
        var v: UInt32 = 0
        for o in p { guard let b = UInt8(o) else { return nil }; v = v << 8 | UInt32(b) }
        return v
    }
    public static func string(_ v: UInt32) -> String { "\(v >> 24).\(v >> 16 & 0xff).\(v >> 8 & 0xff).\(v & 0xff)" }
    public static func mask(_ prefix: Int) -> UInt32 { prefix <= 0 ? 0 : prefix >= 32 ? .max : ~(UInt32.max >> UInt32(prefix)) }
    /// Number of leading one bits of a netmask such as 255.255.255.0 (24).
    public static func prefixLength(ofMask m: UInt32) -> Int { m.nonzeroBitCount }
    /// Multicast (224/4), limited broadcast and 0.0.0.0: never a device.
    public static func isSpecial(_ v: UInt32) -> Bool { v >> 28 == 0xE || v == .max || v == 0 }
    /// 169.254/16, used when DHCP failed or for direct links.
    public static func isLinkLocal(_ v: UInt32) -> Bool { v >> 16 == 0xA9FE }
}

/// An IPv4 address with its prefix length, e.g. 192.168.1.20/24.
public struct IPv4Net: Hashable, Sendable, Codable {
    public var address: String
    public var prefix: Int
    public init(address: String, prefix: Int) { self.address = address; self.prefix = prefix }
    /// The network in CIDR form, e.g. "192.168.1.0/24".
    public var cidr: String {
        guard let a = IPv4.parse(address) else { return address }
        return IPv4.string(a & IPv4.mask(prefix)) + "/\(prefix)"
    }
    public func contains(_ ip: String) -> Bool {
        guard let a = IPv4.parse(address), let b = IPv4.parse(ip) else { return false }
        let m = IPv4.mask(prefix)
        return a & m == b & m
    }
    /// Directed broadcast address of the subnet (all host bits set), which arp lists with an ff:ff:… MAC.
    public var broadcast: String? { IPv4.parse(address).map { IPv4.string($0 | ~IPv4.mask(prefix)) } }
}

/// One neighbour-cache entry: an address the kernel has resolved to a MAC on a local link.
public struct NeighborEntry: Hashable, Sendable {
    public var ip: String
    /// Canonical MAC (`MAC.normalize`).
    public var mac: String
    public var interface: String
    /// Permanent entries are this Mac's own addresses (the kernel never expires them).
    public var permanent: Bool
    public var isIPv6: Bool
    /// ndp's "R" flag: the neighbour has announced itself as an IPv6 router.
    public var isRouter: Bool
    public init(ip: String, mac: String, interface: String, permanent: Bool = false, isIPv6: Bool = false, isRouter: Bool = false) {
        self.ip = ip; self.mac = mac; self.interface = interface; self.permanent = permanent; self.isIPv6 = isIPv6; self.isRouter = isRouter
    }
}

/// Parsers for the kernel's neighbour caches as printed by `arp -an` and `ndp -an`.
public enum Neighbors {
    /// Peer-to-peer and internal interfaces whose "neighbours" are not devices on the user's network: AWDL and
    /// low-latency WLAN (AirDrop, Sidecar, Continuity), loopback, and Apple's internal ethernet-over-USB links.
    static func ignoredInterface(_ ifc: String) -> Bool {
        ["awdl", "llw", "lo", "anpi", "gif", "stf"].contains { ifc.hasPrefix($0) }
    }

    /// `arp -an` lines look like
    ///     ? (192.168.1.20) at b8:27:eb:f7:7:69 on en0 ifscope [ethernet]
    ///     ? (192.168.1.24) at 7e:8d:9d:1e:a0:be on en0 ifscope permanent [ethernet]
    ///     ? (192.168.1.31) at (incomplete) on en0 ifscope [ethernet]
    /// Incomplete entries (the kernel asked and nobody answered), broadcast/multicast entries and ignored interfaces
    /// are dropped.
    public static func parseARP(_ out: String) -> [NeighborEntry] {
        var result: [NeighborEntry] = []
        for line in out.split(separator: "\n") {
            let t = line.split(separator: " ")
            // ["?", "(ip)", "at", "mac", "on", "en0", ...]
            guard t.count >= 6, t[2] == "at", t[4] == "on", t[1].hasPrefix("("), t[1].hasSuffix(")") else { continue }
            let ip = String(t[1].dropFirst().dropLast())
            guard let v = IPv4.parse(ip), !IPv4.isSpecial(v), let mac = MAC.normalize(String(t[3])), !MAC.isGroup(mac) else { continue }
            let ifc = String(t[5])
            guard !ignoredInterface(ifc) else { continue }
            result.append(NeighborEntry(ip: ip, mac: mac, interface: ifc, permanent: t.dropFirst(6).contains("permanent")))
        }
        return result
    }

    /// `ndp -an` prints a header and then columns Neighbor, Linklayer Address, Netif, Expire, St(ate), Flgs:
    ///     fe80::76ac:b9ff:fe5e:21b3%en0           74:ac:b9:5e:21:b3    en0 4s        D  R
    ///     fe80::4c0:8029:a62a:cbc%en0             7e:8d:9d:1e:a0:be    en0 permanent R
    /// State is one letter (R reachable, S stale, D delay…); the optional Flgs column holds "R" for routers. The
    /// "%en0" scope suffix is dropped from the address (the interface is kept separately).
    public static func parseNDP(_ out: String) -> [NeighborEntry] {
        var result: [NeighborEntry] = []
        for line in out.split(separator: "\n") {
            let t = line.split(separator: " ")
            guard t.count >= 5, t[0] != "Neighbor", let mac = MAC.normalize(String(t[1])), !MAC.isGroup(mac) else { continue }
            let ifc = String(t[2])
            guard !ignoredInterface(ifc) else { continue }
            let ip = String(t[0].split(separator: "%").first ?? t[0])
            guard ip.contains(":"), !ip.lowercased().hasPrefix("ff") else { continue }   // ff00::/8 is multicast
            let flags = t.count >= 6 ? String(t[5]) : ""
            result.append(NeighborEntry(ip: ip, mac: mac, interface: ifc, permanent: t[3] == "permanent", isIPv6: true,
                                        isRouter: flags.contains("R")))
        }
        return result
    }
}

/// One hop of a traceroute. `ip` is nil when the hop didn't answer ("*").
public struct TraceHop: Hashable, Sendable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var ip: String?
    public var ms: Double?
    public init(number: Int, ip: String?, ms: Double?) { self.number = number; self.ip = ip; self.ms = ms }
}

public enum Traceroute {
    /// Parses `traceroute -n -q 1` output: one line per hop, e.g. " 1  192.168.1.1  2.345 ms" or " 4  *". A hop that
    /// answered from several addresses keeps the first. The header line goes to stderr, but is skipped if present.
    public static func parse(_ out: String) -> [TraceHop] {
        var hops: [TraceHop] = []
        for line in out.split(separator: "\n") {
            let t = line.split(separator: " ")
            guard let first = t.first, let n = Int(first) else { continue }
            let ip = t.dropFirst().first { IPv4.parse(String($0)) != nil || $0.contains(":") }.map(String.init)
            var ms: Double?
            if let i = t.firstIndex(of: "ms"), i > 0 { ms = Double(t[i - 1]) }
            hops.append(TraceHop(number: n, ip: ip, ms: ms))
        }
        return hops
    }
}
