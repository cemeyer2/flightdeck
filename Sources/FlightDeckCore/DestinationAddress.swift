import Foundation
import Darwin
// Destinations, part 1: what a nettop flow's remote end is. Parses the "proto local<->remote" text nettop prints for
// every connection, classifies the remote address (this Mac, the LAN, link-local, multicast, carrier NAT or the
// internet) and names well-known ports. Pure functions; the tracker (DestinationTracker.swift) calls them once per
// active flow per nettop run.

/// Where an address points. Everything except `publicInternet` is "local": it never leaves this Mac or this network
/// (or, for CGNAT, the provider's network), so it gets no reverse-DNS organisation and is shown apart.
public enum AddressScope: String, Codable, Sendable, CaseIterable {
    case loopback, privateLAN = "private", sharedCGNAT = "cgnat", linkLocal = "link-local", uniqueLocal = "ula",
         multicast, broadcast, unspecified, publicInternet = "public"

    public var isLocal: Bool { self != .publicInternet }
    /// Short label for the UI and MCP output.
    public var label: String {
        switch self {
        case .loopback: "this Mac (loopback)"
        case .privateLAN: "local network"
        case .sharedCGNAT: "carrier-grade NAT (100.64/10)"
        case .linkLocal: "link-local"
        case .uniqueLocal: "local network (IPv6 ULA)"
        case .multicast: "multicast"
        case .broadcast: "broadcast"
        case .unspecified: "unspecified"
        case .publicInternet: "internet"
        }
    }
    /// Loopback, link-local, multicast, broadcast and unspecified addresses have no meaningful PTR record (and
    /// link-local ones would go out as multicast DNS), so they are never looked up. Private, ULA and CGNAT addresses
    /// are: a home router often names its LAN devices.
    public var lookUp: Bool {
        switch self {
        case .privateLAN, .uniqueLocal, .sharedCGNAT, .publicInternet: true
        default: false
        }
    }

    /// Classifies a numeric IPv4 or IPv6 address (an optional "%zone" suffix is ignored). nil if it doesn't parse.
    /// IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) are classified as the IPv4 address they carry.
    public static func of(_ ip: String) -> AddressScope? {
        let bare = ip.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ip
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            return ipv4(withUnsafeBytes(of: v4.s_addr) { Array($0) })
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, bare, &v6) == 1 else { return nil }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return ipv4(Array(b[12..<16])) }
        if b.allSatisfy({ $0 == 0 }) { return .unspecified }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return .loopback }
        if b[0] == 0xff { return .multicast }
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return .linkLocal }      // fe80::/10
        if b[0] & 0xfe == 0xfc { return .uniqueLocal }                    // fc00::/7
        return .publicInternet
    }

    /// `b` is the address in network byte order.
    static func ipv4(_ b: [UInt8]) -> AddressScope {
        switch (b[0], b[1]) {
        case (0, _): return .unspecified
        case (127, _): return .loopback
        case (10, _), (172, 16...31), (192, 168): return .privateLAN
        case (100, 64...127): return .sharedCGNAT
        case (169, 254): return .linkLocal
        case (224...239, _): return .multicast
        default: return b == [255, 255, 255, 255] ? .broadcast : .publicInternet
        }
    }
}

/// The two ends of one nettop flow, as far as destinations care.
public struct FlowEndpoint: Sendable, Equatable {
    /// "tcp", "udp" or "quic" (nettop's "tcp4"/"udp6"/"quic4" without the family digit).
    public var proto: String
    /// Remote address without port, as nettop printed it (IPv6 compressed, possibly with "%zone").
    public var ip: String
    public var remotePort: UInt16?
    public var localPort: UInt16?

    /// Parses "tcp4 192.168.1.5:50725<->17.57.144.90:5223" or "tcp6 fe80::1%en0.5353<->2001:db8::1.443".
    /// IPv4 endpoints separate the port with ":", IPv6 ones with the last ".". Returns nil for flows without a remote
    /// address (listening or unconnected sockets print "*:*" or "*.*"), which can't be attributed to a destination.
    public static func parse<S: StringProtocol>(_ flow: S) -> FlowEndpoint? {
        guard let space = flow.firstIndex(of: " "), let arrow = flow.range(of: "<->") else { return nil }
        let p = flow[..<space]
        let v6 = p.hasSuffix("6")
        let proto = p.last.map { $0.isNumber } == true ? String(p.dropLast()) : String(p)
        let local = flow[flow.index(after: space)..<arrow.lowerBound]
        guard let remote = split(flow[arrow.upperBound...], v6: v6), remote.0 != "*", !remote.0.isEmpty else { return nil }
        return FlowEndpoint(proto: proto, ip: String(remote.0), remotePort: UInt16(remote.1),
                            localPort: split(local, v6: v6).flatMap { UInt16($0.1) })
    }

    /// (address, port) from "a.b.c.d:port" or "v6addr.port". An IPv6 flow can still carry a dotted IPv4 address
    /// (nettop prints v4-mapped peers of dual-stack sockets that way), so a tcp6 endpoint with no ":" splits on ":" too.
    static func split<S: StringProtocol>(_ s: S, v6: Bool) -> (S.SubSequence, S.SubSequence)? {
        let sep: Character = v6 && s.contains(":") ? "." : ":"
        guard let i = s.lastIndex(of: sep) else { return nil }
        return (s[..<i], s[s.index(after: i)...])
    }

    /// The port that names the service. For a connection this Mac opened, that's the remote port. For one opened to a
    /// server on this Mac (SSH, screen sharing, a dev server), the remote port is an ephemeral one and the local port
    /// is the service: that's assumed when the local port is a known or privileged one and the remote port isn't.
    public var servicePort: (port: UInt16, inbound: Bool)? {
        func wellKnown(_ x: UInt16?) -> Bool { x.map { $0 < 1024 || ServiceNames.table[$0] != nil } ?? false }
        if wellKnown(localPort) && !wellKnown(remotePort), let l = localPort { return (l, true) }
        return remotePort.map { ($0, false) }
    }
}

/// Names for common ports. Only well-established assignments; anything else is shown as its number.
public enum ServiceNames {
    static let table: [UInt16: String] = [
        20: "FTP data", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 67: "DHCP", 68: "DHCP", 80: "HTTP",
        88: "Kerberos", 110: "POP3", 123: "NTP", 137: "NetBIOS", 138: "NetBIOS", 139: "SMB", 143: "IMAP", 161: "SNMP",
        389: "LDAP", 443: "HTTPS", 445: "SMB", 465: "SMTP (TLS)", 500: "IPsec IKE", 514: "Syslog", 548: "AFP",
        554: "RTSP", 587: "SMTP (submission)", 631: "IPP (printing)", 636: "LDAPS", 853: "DNS over TLS",
        993: "IMAPS", 995: "POP3S", 1194: "OpenVPN", 1900: "SSDP", 3283: "Apple Remote Desktop", 3478: "STUN/TURN",
        3389: "RDP", 4500: "IPsec NAT-T", 5060: "SIP", 5223: "Apple Push", 5228: "Google Push", 5353: "mDNS",
        5900: "VNC / Screen Sharing", 7000: "AirPlay", 8080: "HTTP (alt)", 8443: "HTTPS (alt)", 19302: "STUN (Google)",
        51820: "WireGuard",
    ]
    /// UDP 443 is QUIC (HTTP/3), not TLS over TCP; nettop lists some QUIC flows as "quic4"/"quic6".
    public static func name(port: UInt16, proto: String) -> String? {
        if port == 443 && proto != "tcp" { return "QUIC (HTTP/3)" }
        return table[port]
    }
    /// "HTTPS 443", "port 8123".
    public static func label(port: UInt16, proto: String) -> String {
        name(port: port, proto: proto).map { "\($0) \(port)" } ?? "port \(port)"
    }
}
