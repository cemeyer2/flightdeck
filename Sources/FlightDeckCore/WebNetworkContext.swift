import Foundation
import Darwin
// Web dashboard, part 2a: what the access decisions need to know about this Mac's network. The app reads it when the
// server starts and again after every network change; tests build it by hand. `read` is the only impure function.

/// One interface and the addresses it holds, each with its on-link prefix length.
public struct WebInterface: Hashable, Sendable {
    public enum Kind: Sendable, Hashable { case lan, tailscale, tunnel, loopback, other }
    public struct Address: Hashable, Sendable {
        public var ip: WebIP
        public var length: Int
        public init(ip: WebIP, length: Int) { self.ip = ip; self.length = length }
        /// The on-link network ("192.168.1.0/24").
        public var prefix: WebPrefix { WebPrefix(address: ip, length: length) }
    }
    public var name: String
    /// "Wi-Fi", "Ethernet" (from SystemConfiguration), else the BSD name.
    public var displayName: String
    public var kind: Kind
    public var addresses: [Address]
    public init(name: String, displayName: String, kind: Kind, addresses: [Address]) {
        self.name = name; self.displayName = displayName; self.kind = kind; self.addresses = addresses
    }
}

public struct WebNetworkContext: Sendable, Equatable {
    public var interfaces: [WebInterface]
    /// SystemConfiguration's LocalHostName ("MacBook-Pro"), for the `<name>.local` Host check.
    public var localHostName: String?
    public var tailscaleProcessRunning: Bool
    /// Settings › Advanced "Allow addresses outside the local network".
    public var advanced: Bool

    public init(interfaces: [WebInterface], localHostName: String?, tailscaleProcessRunning: Bool, advanced: Bool) {
        self.interfaces = interfaces; self.localHostName = localHostName
        self.tailscaleProcessRunning = tailscaleProcessRunning; self.advanced = advanced
    }

    /// A utun interface holds a tailnet address: the only signal that honours tailnet entries.
    public var tailscaleInterfaceUp: Bool { interfaces.contains { $0.kind == .tailscale } }
    /// Either signal: enough to offer "Allow my tailnet", not to honour it.
    public var tailscaleDetected: Bool { tailscaleInterfaceUp || tailscaleProcessRunning }
    /// The on-link prefixes of Wi-Fi and Ethernet interfaces, in interface order, without repeats.
    public var lanPrefixes: [WebPrefix] {
        var seen = Set<WebPrefix>()
        return interfaces.filter { $0.kind == .lan }.flatMap { $0.addresses.map(\.prefix) }.filter { seen.insert($0).inserted }
    }
    public var interfaceAddresses: Set<WebIP> { Set(interfaces.flatMap { $0.addresses.map(\.ip) }) }

    /// The interface holding exactly this address (a connection's local address names the one it arrived on).
    public func interface(owning ip: WebIP) -> WebInterface? {
        interfaces.first { $0.addresses.contains { $0.ip == ip } }
    }

    public static func kind(name: String, addresses: [WebIP], lanNames: Set<String>) -> WebInterface.Kind {
        if name.hasPrefix("lo") { return .loopback }
        if lanNames.contains(name) { return .lan }
        if name.hasPrefix("utun"), addresses.contains(where: WebPrefix.isTailnet) { return .tailscale }
        if ["utun", "ipsec", "ppp", "tap", "tun"].contains(where: { name.hasPrefix($0) }) { return .tunnel }
        return .other   // Thunderbolt Bridge, AWDL, llw, anpi
    }

    /// This Mac's up interfaces from getifaddrs, with netmasks. Wi-Fi and Ethernet are told apart from everything else
    /// by SystemConfiguration (via NetworkDiscovery), so a VPN or bridge never counts as the local network.
    public static func read(localHostName: String?, tailscaleProcessRunning: Bool, advanced: Bool) -> WebNetworkContext {
        let known = NetworkDiscovery.interfaces()
        let lanNames = Set(known.filter { $0.kind == .wifi || $0.kind == .ethernet }.map(\.name))
        let display = Dictionary(known.map { ($0.name, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = [], addrs: [String: [WebInterface.Address]] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            defer { freeifaddrs(ifap) }
            for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let a = p.pointee
                guard a.ifa_flags & UInt32(IFF_UP) != 0, let sa = a.ifa_addr, let ip = Self.ip(sa, family: sa.pointee.sa_family) else { continue }
                let name = String(cString: a.ifa_name)
                if addrs[name] == nil { order.append(name) }
                let length = a.ifa_netmask.flatMap { Self.ip($0, family: sa.pointee.sa_family, mask: true) }.map { $0.bytes.reduce(0) { $0 + $1.nonzeroBitCount } } ?? ip.bytes.count * 8
                addrs[name, default: []].append(.init(ip: ip, length: length))
            }
        }
        let ifs = order.map { n in
            WebInterface(name: n, displayName: display[n].flatMap { lanNames.contains(n) ? $0 : nil } ?? n,
                         kind: kind(name: n, addresses: addrs[n]!.map(\.ip), lanNames: lanNames), addresses: addrs[n]!)
        }
        return WebNetworkContext(interfaces: ifs, localHostName: localHostName, tailscaleProcessRunning: tailscaleProcessRunning, advanced: advanced)
    }

    /// The address in an AF_INET or AF_INET6 sockaddr. A netmask's sockaddr may be short (only the significant bytes
    /// are present) and carry no family, so the family is the address's and bytes past `sa_len` are zero.
    static func ip(_ sa: UnsafeMutablePointer<sockaddr>, family: sa_family_t, mask: Bool = false) -> WebIP? {
        let len = Int(sa.pointee.sa_len)
        let raw = UnsafeRawPointer(sa)
        func bytes(at offset: Int, count: Int) -> [UInt8] {
            (0..<count).map { offset + $0 < len ? raw.load(fromByteOffset: offset + $0, as: UInt8.self) : 0 }
        }
        switch Int32(family) {
        case AF_INET:
            return WebIP(bytes: bytes(at: MemoryLayout<sockaddr_in>.offset(of: \sockaddr_in.sin_addr)!, count: 4))
        case AF_INET6:
            var b = bytes(at: MemoryLayout<sockaddr_in6>.offset(of: \sockaddr_in6.sin6_addr)!, count: 16)
            // The kernel embeds the scope (interface index) in bytes 2–3 of link-local addresses; the wire has zeros.
            if !mask && b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { b[2] = 0; b[3] = 0 }
            return mask ? WebIP(rawUnfolded: b) : WebIP(bytes: b)
        default: return nil
        }
    }
}
