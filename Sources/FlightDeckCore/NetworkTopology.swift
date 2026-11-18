import Foundation

// Network map, part 4: the topology the map draws. Only what this Mac can actually observe is modelled: which of its
// interfaces are up, which subnet each is on, which devices were seen through each interface, which interface carries
// the default route (and so leads to the internet), and the hops of an optional traceroute. Link-layer topology
// (which switch port or access point a device uses) is not observable from a Mac on a home network, so devices are
// attached to their subnet, never to each other or to the router.

/// The Wi-Fi access point this Mac is associated with, as far as CoreWLAN reveals it.
public struct AccessPoint: Hashable, Sendable {
    public var ssid: String?      // nil without Location permission
    public var bssid: String?     // nil without Location permission
    public var channel: String?   // e.g. "36 · 5 GHz · 80 MHz"
    public var rssi: Int?
    public init(ssid: String?, bssid: String?, channel: String?, rssi: Int?) { self.ssid = ssid; self.bssid = bssid; self.channel = channel; self.rssi = rssi }
}

/// One interface of this Mac and what hangs off it.
public struct NetBranch: Identifiable, Hashable, Sendable {
    public var id: String { interface.name }
    public var interface: NetInterface
    /// Subnets of the interface in CIDR form ("192.168.1.0/24"); empty for IPv6-only interfaces.
    public var subnets: [String]
    /// Wi-Fi association, for Wi-Fi interfaces.
    public var accessPoint: AccessPoint?
    /// Device ids seen through this interface (excluding This Mac and the gateway).
    public var devices: [String]
    /// The gateway device's id, when the default route uses this interface.
    public var gateway: String?
    /// True when the default route leaves through this interface, i.e. it leads to the internet.
    public var carriesDefaultRoute: Bool
}

public struct NetTopology: Hashable, Sendable {
    /// Branches, the default-route one first.
    public var branches: [NetBranch]
    /// Traceroute hops beyond the gateway (the first hop, when it is the gateway, is dropped).
    public var hops: [TraceHop]
    /// The interface the default route uses (a utun name when a full-tunnel VPN is on); nil when offline.
    public var defaultRouteInterface: String?

    /// True when the default route goes through a VPN interface: internet traffic then leaves through the tunnel,
    /// whose own traffic is carried by one of the physical branches (which one isn't shown by the routing table alone).
    public var internetViaVPN: Bool { primary?.carriesDefaultRoute == true && primary?.interface.kind == .vpn }

    public var primary: NetBranch? { branches.first }

    /// Builds the topology. Interfaces that aren't active (`NetInterface.isActive`) get no branch. Devices whose
    /// interface isn't one of the branches (e.g. seen on an interface that has since gone down) are left out of the
    /// map but still appear in the list.
    public static func build(interfaces: [NetInterface], devices: [NetDevice], route: DefaultRoute?, wifi: AccessPoint?,
                             hops: [TraceHop] = []) -> NetTopology {
        let gateway = devices.first { $0.isGateway }
        var branches: [NetBranch] = interfaces.filter(\.isActive).map { i in
            let carries = route?.interface == i.name
            let members = devices.filter { !$0.isThisMac && !($0.isGateway && carries) && $0.interface == i.name }
            return NetBranch(interface: i, subnets: Array(Set(i.ipv4.filter { !(IPv4.parse($0.address).map(IPv4.isLinkLocal) ?? true) }.map(\.cidr))).sorted(),
                             accessPoint: i.kind == .wifi ? wifi : nil,
                             devices: members.map(\.id), gateway: carries ? gateway?.id : nil, carriesDefaultRoute: carries)
        }
        // Default route first, then physical interfaces with the most devices, then VPNs; stable by name.
        branches.sort { a, b in
            if a.carriesDefaultRoute != b.carriesDefaultRoute { return a.carriesDefaultRoute }
            if (a.interface.kind == .vpn) != (b.interface.kind == .vpn) { return b.interface.kind == .vpn }
            if a.devices.count != b.devices.count { return a.devices.count > b.devices.count }
            return a.interface.name < b.interface.name
        }
        var h = hops
        if let first = h.first, let g = gateway, let ip = first.ip, g.ipv4.contains(ip) || g.ipv6.contains(ip) { h.removeFirst() }
        return NetTopology(branches: branches, hops: h, defaultRouteInterface: route?.interface)
    }
}
