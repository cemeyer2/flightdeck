import Foundation
import CoreWLAN
import SystemConfiguration

// Network map, part 5: the live collectors. Everything here works without root and without an admin prompt:
// getifaddrs and SystemConfiguration for this Mac's interfaces, `arp -an` / `ndp -an` for the kernel's neighbour
// caches (reading them sends nothing), the routing table for the gateway, CoreWLAN for the access point, and the system
// resolver for reverse DNS. Bonjour browsing is in BonjourBrowser.swift; the opt-in active scan and traceroute are at
// the bottom. Nothing here runs unless the Network view asks for it.

/// Everything one refresh of the Network view learned.
public struct NetworkSurvey: Sendable {
    public var time: Date
    public var interfaces: [NetInterface]
    public var devices: [NetDevice]
    public var topology: NetTopology
    public var route: DefaultRoute?
    public var dns: [String]
    public var accessPoint: AccessPoint?
    /// Plain-English notes about what couldn't be learned and why (shown under the map).
    public var notes: [String]
    public init(time: Date, interfaces: [NetInterface], devices: [NetDevice], topology: NetTopology, route: DefaultRoute?,
                dns: [String], accessPoint: AccessPoint?, notes: [String]) {
        self.time = time; self.interfaces = interfaces; self.devices = devices; self.topology = topology; self.route = route
        self.dns = dns; self.accessPoint = accessPoint; self.notes = notes
    }
    public func device(_ id: String?) -> NetDevice? { id.flatMap { i in devices.first { $0.id == i } } }
}

public enum NetworkDiscovery {
    /// This Mac's interfaces with their addresses. Kinds come from SystemConfiguration (which knows Wi-Fi from
    /// Ethernet and names "Thunderbolt Bridge"); utun/ipsec/ppp interfaces, which SystemConfiguration doesn't list,
    /// are VPN tunnels. Peer-to-peer and loopback interfaces are skipped.
    public static func interfaces() -> [NetInterface] {
        var names: [String: (String, InterfaceKind)] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
                let type = SCNetworkInterfaceGetInterfaceType(i) as String? ?? ""
                let display = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? ?? bsd
                let kind: InterfaceKind = type == (kSCNetworkInterfaceTypeIEEE80211 as String) ? .wifi
                    : type == (kSCNetworkInterfaceTypeEthernet as String) ? .ethernet
                    : type == "Bridge" ? .bridge : .other   // "Bridge" is SystemConfiguration's private-constant value for Thunderbolt Bridge
                names[bsd] = (display, kind)
            }
        }
        for w in CWWiFiClient.shared().interfaceNames() ?? [] { names[w] = (names[w]?.0 ?? "Wi-Fi", .wifi) }

        var byName: [String: NetInterface] = [:]
        var order: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            let name = String(cString: a.ifa_name)
            guard !Neighbors.ignoredInterface(name), a.ifa_flags & UInt32(IFF_UP) != 0, let sa = a.ifa_addr else { continue }
            if byName[name] == nil {
                let vpn = ["utun", "ipsec", "ppp", "tap", "tun"].contains { name.hasPrefix($0) }
                let (display, kind) = vpn ? ("VPN tunnel", InterfaceKind.vpn) : (names[name] ?? (name, .other))
                byName[name] = NetInterface(name: name, displayName: display, kind: kind); order.append(name)
            }
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                guard let ip = numericHost(sa) else { continue }
                var prefix = 32
                if let m = a.ifa_netmask, let ms = numericHost(m), let mv = IPv4.parse(ms) { prefix = IPv4.prefixLength(ofMask: mv) }
                byName[name]?.ipv4.append(IPv4Net(address: ip, prefix: prefix))
            case AF_INET6:
                if let ip = numericHost(sa) { byName[name]?.ipv6.append(String(ip.split(separator: "%")[0])) }
            case AF_LINK:
                // sockaddr_dl: the link-layer address follows the interface name inside sdl_data.
                sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    let d = dl.pointee
                    guard d.sdl_alen == 6 else { return }
                    let base = UnsafeRawPointer(dl).advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)! + Int(d.sdl_nlen))
                    let bytes = (0..<6).map { base.load(fromByteOffset: $0, as: UInt8.self) }
                    if bytes.contains(where: { $0 != 0 }) { byName[name]?.mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":") }
                }
            default: break
            }
        }
        return order.compactMap { byName[$0] }
    }

    /// Numeric address of a sockaddr via getnameinfo (handles both families and IPv6 scope).
    static func numericHost(_ sa: UnsafePointer<sockaddr>) -> String? {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(sa.pointee.sa_family == AF_INET6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
        guard getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buf)
    }

    /// The kernel's IPv4 and IPv6 neighbour caches. Reading them sends no packets.
    public static func neighbors() -> [NeighborEntry] {
        Neighbors.parseARP(Shell.run("/usr/sbin/arp", ["-an"], timeout: 5) ?? "")
            + Neighbors.parseNDP(Shell.run("/usr/sbin/ndp", ["-an"], timeout: 5) ?? "")
    }

    public static func defaultRoute() -> DefaultRoute? { NetworkConfig.defaultRoute().map { DefaultRoute(gateway: $0.gateway, interface: $0.interface) } }

    /// The associated access point. SSID and BSSID are nil unless the app has Location Services permission
    /// (macOS treats them as location data); the channel and signal are always readable.
    public static func accessPoint() -> AccessPoint? {
        guard let w = WiFiInfo.current() else { return nil }
        let bssid = CWWiFiClient.shared().interface()?.bssid().flatMap(MAC.normalize)
        let ch = [w.channel.map(String.init), w.band, w.width].compactMap { $0 }.joined(separator: " · ")
        return AccessPoint(ssid: w.ssid, bssid: bssid, channel: ch.isEmpty ? nil : ch, rssi: w.rssi)
    }

    /// Reverse DNS (PTR) names for addresses, looked up in parallel through the system resolver. Lookups still
    /// running after `timeout` are abandoned (their late answers are discarded). Addresses without a PTR record are
    /// absent from the result, as are answers that just echo the address back.
    public static func reverseDNS(_ ips: [String], timeout: TimeInterval = 3) -> [String: String] {
        final class Box: @unchecked Sendable { let lock = NSLock(); var out: [String: String] = [:] }
        let box = Box(), group = DispatchGroup()
        for ip in Set(ips) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                guard let name = ptr(ip) else { return }
                box.lock.lock(); box.out[ip] = name; box.lock.unlock()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        box.lock.lock(); defer { box.lock.unlock() }
        return box.out
    }

    /// One blocking PTR lookup. NI_NAMEREQD makes getnameinfo fail instead of returning the numeric address.
    static func ptr(_ ip: String) -> String? {
        var hints = addrinfo(); hints.ai_flags = AI_NUMERICHOST
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(r.pointee.ai_addr, r.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        var name = String(cString: buf)
        if name.hasSuffix(".") { name.removeLast() }
        return name == ip ? nil : name
    }

    /// One survey: interfaces, route, neighbour caches, reverse DNS (for addresses not in `knownNames`), plus the
    /// Bonjour services the caller collected, merged and laid out. `seen` carries first-seen times between refreshes.
    public static func survey(services: [BonjourService], knownNames: [String: String], seen: [String: (first: Date, last: Date)],
                              hops: [TraceHop], doReverseDNS: Bool = true) -> (NetworkSurvey, names: [String: String]) {
        let ifs = interfaces(), route = defaultRoute(), nb = neighbors(), ap = accessPoint()
        var names = knownNames
        if doReverseDNS {
            let todo = Set(nb.map(\.ip).filter { !$0.contains(":") } + [route?.gateway].compactMap { $0 }).subtracting(names.keys)
            let found = reverseDNS(Array(todo))
            // Misses are remembered as "" so the 10 s re-reads don't repeat lookups that already failed.
            for ip in todo { names[ip] = found[ip] ?? "" }
        }
        let devices = NetworkInventory.merge(interfaces: ifs, neighbors: nb, services: services, reverseDNS: names.filter { !$0.value.isEmpty },
                                             route: route, seen: seen)
        let topo = NetTopology.build(interfaces: ifs, devices: devices, route: route, wifi: ap, hops: hops)
        var notes: [String] = []
        if route == nil { notes.append("No default route: this Mac isn't connected to a network with a router.") }
        if let ap, ap.bssid == nil { notes.append("Wi-Fi network name and access point (BSSID) are hidden by macOS unless FlightDeck has Location Services permission.") }
        return (NetworkSurvey(time: Date(), interfaces: ifs, devices: devices, topology: topo, route: route, dns: NetworkConfig.dnsServers(),
                              accessPoint: ap, notes: notes), names)
    }
}
