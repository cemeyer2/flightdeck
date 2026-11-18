import Foundation

// Network map, part 2: what is known about each device. Discovery results (neighbour caches, Bonjour services,
// reverse DNS, this Mac's interfaces, the default route) are merged into one `NetDevice` per device, and each
// device gets a guessed type with the reason for the guess. Pure functions over plain values, so they are tested with
// invented inputs.

/// Kind of a local interface of this Mac.
public enum InterfaceKind: String, Sendable, Codable, Hashable {
    case wifi = "Wi-Fi", ethernet = "Ethernet", vpn = "VPN", bridge = "Bridge", other = "Other"
}

/// One of this Mac's network interfaces with its addresses.
public struct NetInterface: Hashable, Sendable, Codable, Identifiable {
    public var id: String { name }
    public var name: String              // BSD name, e.g. en0, utun4
    public var displayName: String       // "Wi-Fi", "Ethernet", "Thunderbolt Bridge", "VPN tunnel"
    public var kind: InterfaceKind
    public var mac: String?
    public var ipv4: [IPv4Net]
    public var ipv6: [String]
    public init(name: String, displayName: String, kind: InterfaceKind, mac: String? = nil, ipv4: [IPv4Net] = [], ipv6: [String] = []) {
        self.name = name; self.displayName = displayName; self.kind = kind; self.mac = mac; self.ipv4 = ipv4; self.ipv6 = ipv6
    }
    /// IPv6 addresses outside fe80::/10, i.e. ones that route beyond the link.
    public var globalIPv6: [String] { ipv6.filter { !$0.lowercased().hasPrefix("fe80") } }
    /// Whether the interface carries traffic worth a branch on the map: an IPv4 address that isn't link-local, or a
    /// global IPv6 address. (macOS keeps several idle utun interfaces with only link-local IPv6 for system services.)
    public var isActive: Bool {
        ipv4.contains { IPv4.parse($0.address).map { !IPv4.isLinkLocal($0) } ?? false } || !globalIPv6.isEmpty
    }
}

/// One resolved Bonjour (mDNS/DNS-SD) service instance.
public struct BonjourService: Hashable, Sendable {
    public var name: String              // instance name, e.g. "Living Room"
    public var type: String              // "_airplay._tcp"
    public var interface: String?
    public var host: String?             // target host, e.g. "Living-Room.local."
    public var addresses: [String]
    public var txt: [String: String]
    public init(name: String, type: String, interface: String? = nil, host: String? = nil, addresses: [String] = [], txt: [String: String] = [:]) {
        self.name = name; self.type = type; self.interface = interface; self.host = host; self.addresses = addresses; self.txt = txt
    }
}

/// Guessed device type, with an SF Symbol for the map.
public enum DeviceKind: String, Sendable, Codable, Hashable, CaseIterable {
    case router = "Router", thisMac = "This Mac", computer = "Computer", phone = "Phone", tablet = "Tablet",
         watch = "Watch", tv = "TV / streamer", speaker = "Speaker", printer = "Printer", nas = "NAS / file server",
         camera = "Camera", smartHome = "Smart home", console = "Game console", networkGear = "Network equipment",
         unknown = "Unknown"
    public var icon: String {
        switch self {
        case .router: "wifi.router"; case .thisMac: "laptopcomputer"; case .computer: "desktopcomputer"
        case .phone: "iphone"; case .tablet: "ipad"; case .watch: "applewatch"; case .tv: "tv"
        case .speaker: "hifispeaker"; case .printer: "printer"; case .nas: "externaldrive.connected.to.line.below"
        case .camera: "video"; case .smartHome: "lightbulb"; case .console: "gamecontroller"
        case .networkGear: "network"; case .unknown: "questionmark.circle"
        }
    }
}

/// A device on the local network, merged from every source that mentioned it.
public struct NetDevice: Identifiable, Hashable, Sendable {
    /// "mac:<mac>" when a MAC is known, otherwise "ip:<address>" (stable across refreshes either way).
    public var id: String
    public var mac: String?
    public var ipv4: [String] = []
    public var ipv6: [String] = []
    public var interface: String?
    /// PTR name from reverse DNS, if the network's DNS server has one.
    public var hostname: String?
    /// Bonjour host name without ".local.", e.g. "Living-Room".
    public var bonjourHost: String?
    /// Bonjour instance names, e.g. "Living Room" (AirPlay) or "Brother HL-L2350DW" (IPP).
    public var bonjourNames: [String] = []
    /// Advertised service types, e.g. "_airplay._tcp".
    public var services: [String] = []
    /// Model identifier or name from TXT records (e.g. "AppleTV14,1", "Chromecast"), when advertised.
    public var model: String?
    public var vendor: Vendor = .noMAC
    public var isGateway = false
    public var isIPv6Router = false
    public var isThisMac = false
    public var kind: DeviceKind = .unknown
    /// Why `kind` was chosen, in plain English ("advertises a printer service (_ipp._tcp)").
    public var kindReason = "nothing identifying was seen"
    /// Where the device was seen: "ARP", "NDP", "Bonjour", "route", "this Mac".
    public var sources: [String] = []
    /// UPnP friendly name and manufacturer, when the device answers UPnP discovery (see NetworkEnrichment).
    public var upnpName: String?
    public var manufacturer: String?
    /// The name given to this client in a configured UniFi console, and where the console says it's attached
    /// ("Wi-Fi via Office AP (Home) · 866 Mbps", "Rack Switch port 5 · 1 Gbps"): the physical topology this Mac can't see.
    public var unifiName: String?
    public var attachment: String?
    public var firstSeen = Date.distantPast
    public var lastSeen = Date.distantPast

    public init(id: String) { self.id = id }

    /// Best name to show: a Bonjour instance or host name the device chose, then reverse DNS, then vendor, then IP.
    public var displayName: String {
        if isThisMac { return "This Mac" }
        // A name someone chose for the device beats one derived from it: the UniFi alias, then what it announces.
        if let n = unifiName { return n }
        if let n = preferredBonjourName { return n }
        if let n = upnpName { return n }
        if let h = bonjourHost { return h }
        if let h = hostname { return h }
        if isGateway { return "Router" }
        if let v = vendor.name { return "\(v) device" }
        return ipv4.first ?? ipv6.first ?? "Unknown device"
    }

    /// Instance names other than ones that embed a MAC ("A1B2C3D4E5F6@Living Room" from RAOP is cleaned up).
    var preferredBonjourName: String? {
        bonjourNames.lazy.map { n in n.split(separator: "@", maxSplits: 1).count == 2 ? String(n.split(separator: "@")[1]) : n }.first
    }

    /// Primary address for sorting and display.
    public var primaryIP: String { ipv4.first ?? ipv6.first ?? "—" }
}

/// Facts about this Mac's routing that identify the gateway.
public struct DefaultRoute: Hashable, Sendable {
    public var gateway: String
    public var interface: String
    public init(gateway: String, interface: String) { self.gateway = gateway; self.interface = interface }
}

public enum NetworkInventory {
    /// Merges discovery results into devices.
    /// - `seen`: first/last-seen times from earlier refreshes, keyed by device id; devices seen now get `now` as their
    ///   last-seen time, devices not seen now are dropped (the caller keeps history if it wants to show stale ones).
    /// - Bonjour services are matched to devices by IP address, so a service whose addresses didn't resolve, or
    ///   resolved only to addresses that aren't in any neighbour cache, becomes its own IP-keyed device.
    public static func merge(interfaces: [NetInterface], neighbors: [NeighborEntry], services: [BonjourService],
                             reverseDNS: [String: String], route: DefaultRoute?, seen: [String: (first: Date, last: Date)] = [:],
                             now: Date = Date()) -> [NetDevice] {
        var devices: [String: NetDevice] = [:]
        var byIP: [String: String] = [:]      // address → device id
        let ownMACs = Set(interfaces.compactMap(\.mac))
        let ownIPs = Set(interfaces.flatMap { $0.ipv4.map(\.address) + $0.ipv6 })

        func add(_ id: String, _ body: (inout NetDevice) -> Void) {
            var d = devices[id] ?? NetDevice(id: id)
            body(&d)
            devices[id] = d
        }
        func note(_ d: inout NetDevice, _ source: String) { if !d.sources.contains(source) { d.sources.append(source) } }
        func addIP(_ d: inout NetDevice, _ ip: String) {
            if ip.contains(":") { if !d.ipv6.contains(ip) { d.ipv6.append(ip) } } else if !d.ipv4.contains(ip) { d.ipv4.append(ip) }
            byIP[ip] = d.id
        }

        // This Mac: one device for all its interfaces, so its own ARP/NDP entries and Bonjour services land on it.
        add("this-mac") { d in
            d.isThisMac = true; note(&d, "this Mac")
            d.mac = interfaces.first(where: { $0.name == route?.interface })?.mac ?? interfaces.compactMap(\.mac).first
            for i in interfaces where i.isActive { for a in i.ipv4 { addIP(&d, a.address) }; for a in i.globalIPv6 { addIP(&d, a) } }
            d.interface = route?.interface
        }
        for n in neighbors {
            // Permanent entries are this Mac's own addresses, already taken from its interfaces above.
            if n.permanent || ownMACs.contains(n.mac) || ownIPs.contains(n.ip) { continue }
            add("mac:" + n.mac) { d in
                d.mac = n.mac; d.interface = d.interface ?? n.interface
                addIP(&d, n.ip); note(&d, n.isIPv6 ? "NDP" : "ARP")
                if n.isRouter { d.isIPv6Router = true }
            }
        }
        // The default gateway is in the routing table even before it's in the ARP cache.
        if let r = route, IPv4.parse(r.gateway) != nil || r.gateway.contains(":") {
            let id = byIP[r.gateway] ?? "ip:" + r.gateway
            add(id) { d in d.isGateway = true; addIP(&d, r.gateway); note(&d, "route"); d.interface = d.interface ?? r.interface }
        }
        for s in services {
            let id = s.addresses.lazy.compactMap { byIP[$0] }.first ?? s.addresses.first.map { "ip:" + $0 }
            guard let id else { continue }   // unresolved: nothing ties it to a device
            add(id) { d in
                note(&d, "Bonjour")
                for a in s.addresses { addIP(&d, a) }
                if !d.services.contains(s.type) { d.services.append(s.type) }
                if !d.bonjourNames.contains(s.name) && s.type != "_device-info._tcp" { d.bonjourNames.append(s.name) }
                if let h = s.host { d.bonjourHost = d.bonjourHost ?? cleanHost(h) }
                if let m = model(from: s) { d.model = d.model ?? m }
                d.interface = d.interface ?? s.interface
            }
        }
        for (ip, name) in reverseDNS.sorted(by: { $0.key < $1.key }) { if let id = byIP[ip] { add(id) { $0.hostname = $0.hostname ?? name } } }

        return devices.values.map { d0 in
            var d = d0
            d.vendor = OUI.lookup(d.mac)
            d.ipv4.sort { (IPv4.parse($0) ?? 0) < (IPv4.parse($1) ?? 0) }
            d.services.sort()
            let g = DeviceClassifier.guess(d); d.kind = g.kind; d.kindReason = g.reason
            d.firstSeen = seen[d.id]?.first ?? now; d.lastSeen = now
            return d
        }.sorted { a, b in
            if a.isThisMac != b.isThisMac { return a.isThisMac }
            if a.isGateway != b.isGateway { return a.isGateway }
            return (IPv4.parse(a.ipv4.first ?? "") ?? .max) < (IPv4.parse(b.ipv4.first ?? "") ?? .max)
        }
    }

    /// "Living-Room.local." → "Living-Room".
    static func cleanHost(_ h: String) -> String {
        var s = h.hasSuffix(".") ? String(h.dropLast()) : h
        if s.hasSuffix(".local") { s = String(s.dropLast(6)) }
        return s
    }

    /// The model a service's TXT record advertises: `model` (_device-info, _airplay), `md` (Google Cast, HomeKit),
    /// `am` (AirPlay audio), `ty` or `product` (printers). nil when none is present.
    static func model(from s: BonjourService) -> String? {
        for k in ["model", "md", "am", "ty", "product"] {
            if var v = s.txt[k]?.trimmingCharacters(in: .whitespaces), !v.isEmpty {
                if v.hasPrefix("("), v.hasSuffix(")") { v = String(v.dropFirst().dropLast()) }   // IPP "product=(HL-L2350DW)"
                return v
            }
        }
        return nil
    }
}
