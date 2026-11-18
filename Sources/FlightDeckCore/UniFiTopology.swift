// Builds the real layer-2 topology of a UniFi network from the uplink fields in a snapshot: each device's
// `uplink.parentMAC` / `parentPort` (classic `uplink_mac` / `uplink_remote_port`, or `last_uplink` for a device that just
// dropped off; integration `uplink.deviceId`), and each client's `apMAC` (classic `ap_mac`) or `switchMAC` + `switchPort`
// (classic `sw_mac` / `sw_port`). Also merges records of the same device from the two APIs.
import Foundation

/// Where one MAC address is attached, for consumers like the network map.
public struct UniFiAttachment: Sendable, Hashable {
    public enum Link: Sendable, Hashable {
        /// Associated with this AP, on this SSID (nil if unknown).
        case wireless(ssid: String?)
        /// Plugged into this port of a switch or gateway (nil when the console names the switch but not the port).
        case wired(port: Int?)
        /// The console names the device but not how the MAC is attached.
        case unknown
    }
    /// Normalized MAC of the AP, switch or gateway.
    public var deviceMAC: String
    public var deviceName: String
    public var link: Link
    /// Link speed in Mbit/s when reported (port speed for wired, PHY rate for wireless).
    public var speedMbps: Int?
}

public extension UniFiSnapshot {
    /// Which AP or switch port the device or client with this MAC is on, or nil if the console doesn't know it (or the
    /// MAC isn't on this network). Works for UniFi devices too (a switch's uplink port on its parent).
    func attachment(ofMAC raw: String) -> UniFiAttachment? {
        let mac = UniFi.normalizeMAC(raw)
        if let c = clients.first(where: { $0.mac == mac }), let parent = c.parentMAC, let d = device(mac: parent) {
            let link: UniFiAttachment.Link = c.wired == false ? .wireless(ssid: c.ssid)
                : c.wired == true || c.switchPort != nil ? .wired(port: c.switchPort) : d.kind == .accessPoint ? .wireless(ssid: c.ssid) : .unknown
            return UniFiAttachment(deviceMAC: d.mac, deviceName: d.displayName, link: link, speedMbps: c.linkSpeedMbps)
        }
        if let d = device(mac: mac), let u = d.uplink, let parent = u.parentMAC, let pd = device(mac: parent) {
            return UniFiAttachment(deviceMAC: pd.mac, deviceName: pd.displayName,
                                   link: u.wireless == true ? .wireless(ssid: nil) : .wired(port: u.parentPort), speedMbps: u.speedMbps)
        }
        return nil
    }

    /// Clients on one device (AP or switch), optionally only those on one port.
    func clients(on deviceMAC: String, port: Int? = nil) -> [UniFiClient] {
        let mac = UniFi.normalizeMAC(deviceMAC)
        return clients.filter { $0.parentMAC == mac && (port == nil || $0.switchPort == port) }
    }

    var topology: UniFiTopology { UniFiTopology(self) }
}

/// A tree of devices (gateway at the root) with clients hung under their AP or switch port.
public struct UniFiTopology: Sendable {
    public struct Node: Sendable, Identifiable {
        public var id: String { device.mac }
        public var device: UniFiDevice
        /// Port on the parent this device is plugged into, and the link speed, when reported.
        public var parentPort: Int?
        public var linkMbps: Int?
        public var children: [Node]
        /// Clients attached to this device without a known port (all wireless clients of an AP, and wired clients
        /// whose port the console didn't name).
        public var clients: [UniFiClient]
        /// Wired clients by the port they're on.
        public var portClients: [Int: [UniFiClient]]
    }
    public var roots: [Node]
    /// Clients whose AP/switch the console didn't report or isn't in the device list.
    public var unattached: [UniFiClient]

    public init(_ s: UniFiSnapshot) {
        let byMAC = Dictionary(s.devices.map { ($0.mac, $0) }, uniquingKeysWith: { a, _ in a })
        // A parent is only used if it exists and isn't the device itself; cycles are cut while walking below.
        func parent(_ d: UniFiDevice) -> String? { d.uplink?.parentMAC.flatMap { $0 != d.mac && byMAC[$0] != nil ? $0 : nil } }
        var childrenOf: [String: [UniFiDevice]] = [:]
        for d in s.devices { if let p = parent(d) { childrenOf[p, default: []].append(d) } }
        var clientsOf: [String: [UniFiClient]] = [:], loose: [UniFiClient] = []
        for c in s.clients {
            if let p = c.parentMAC, byMAC[p] != nil { clientsOf[p, default: []].append(c) } else { loose.append(c) }
        }
        let order: [UniFiDeviceKind: Int] = [.gateway: 0, .switch: 1, .accessPoint: 2, .other: 3]
        func sortDevices(_ a: [UniFiDevice]) -> [UniFiDevice] {
            a.sorted { (order[$0.kind]!, $0.uplink?.parentPort ?? 0, $0.displayName) < (order[$1.kind]!, $1.uplink?.parentPort ?? 0, $1.displayName) }
        }
        var visited = Set<String>()
        func node(_ d: UniFiDevice) -> Node {
            visited.insert(d.mac)
            let kids = sortDevices(childrenOf[d.mac] ?? []).filter { !visited.contains($0.mac) }.map(node)
            let cs = (clientsOf[d.mac] ?? []).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            // Wired clients with a port go under that port (an AP's ethernet port counts too); the rest hang off the device.
            let ported = cs.filter { $0.wired != false && $0.switchPort != nil && $0.switchMAC == d.mac }
            return Node(device: d, parentPort: d.uplink?.parentPort, linkMbps: d.uplink?.speedMbps, children: kids,
                        clients: cs.filter { c in !ported.contains { $0.mac == c.mac } },
                        portClients: Dictionary(grouping: ported) { $0.switchPort! })
        }
        var roots = sortDevices(s.devices.filter { parent($0) == nil }).map(node)
        // Devices only reachable through a cycle (bad data) would otherwise vanish; list them as extra roots.
        for d in sortDevices(s.devices) where !visited.contains(d.mac) { roots.append(node(d)) }
        self.roots = roots
        self.unattached = loose
    }

    /// Every node, depth-first, with its depth (for flat rendering).
    public var flattened: [(node: Node, depth: Int)] {
        var out: [(Node, Int)] = []
        func walk(_ n: Node, _ depth: Int) { out.append((n, depth)); n.children.forEach { walk($0, depth + 1) } }
        roots.forEach { walk($0, 0) }
        return out
    }
}

/// Merging the integration API's records with classic ones for the same MACs.
enum UniFiMerge {
    static func fill<T>(_ a: inout T?, _ b: T?) { if a == nil { a = b } }

    /// `primary` (integration) wins wherever it has a value; `extra` (classic) fills in the gaps. Records only in
    /// `extra` are added.
    static func devices(_ primary: [UniFiDevice], _ extra: [UniFiDevice]) -> [UniFiDevice] {
        var out = primary
        for e in extra {
            guard let i = out.firstIndex(where: { $0.mac == e.mac }) else { out.append(e); continue }
            var d = out[i]
            fill(&d.name, e.name); fill(&d.model, e.model); fill(&d.ip, e.ip); fill(&d.firmware, e.firmware)
            fill(&d.uptime, e.uptime); fill(&d.state, e.state); fill(&d.online, e.online); fill(&d.cpuPercent, e.cpuPercent)
            fill(&d.memoryPercent, e.memoryPercent); fill(&d.clientCount, e.clientCount); fill(&d.rxBps, e.rxBps); fill(&d.txBps, e.txBps)
            if d.kind == .other { d.kind = e.kind }
            if d.temperatures.isEmpty { d.temperatures = e.temperatures }
            // Classic port and radio tables are richer (PoE watts, utilization, client counts), so they replace ours.
            if !e.ports.isEmpty { d.ports = e.ports }
            if !e.radios.isEmpty { d.radios = e.radios }
            // The classic uplink includes the parent port and speed, which the integration API lacks.
            if let eu = e.uplink {
                var u = d.uplink ?? UniFiUplink()
                fill(&u.parentMAC, eu.parentMAC); fill(&u.parentPort, eu.parentPort); fill(&u.localPort, eu.localPort)
                fill(&u.speedMbps, eu.speedMbps); fill(&u.wireless, eu.wireless)
                d.uplink = u
            }
            out[i] = d
        }
        return out
    }

    static func clients(_ primary: [UniFiClient], _ extra: [UniFiClient]) -> [UniFiClient] {
        var out = primary
        for e in extra {
            guard let i = out.firstIndex(where: { $0.mac == e.mac }) else { out.append(e); continue }
            var c = out[i]
            fill(&c.name, e.name); fill(&c.hostname, e.hostname); fill(&c.ip, e.ip); fill(&c.vendor, e.vendor); fill(&c.wired, e.wired)
            fill(&c.apMAC, e.apMAC); fill(&c.ssid, e.ssid); fill(&c.signalDbm, e.signalDbm); fill(&c.rssi, e.rssi)
            fill(&c.channel, e.channel); fill(&c.wifiStandard, e.wifiStandard); fill(&c.band, e.band)
            fill(&c.switchMAC, e.switchMAC); fill(&c.switchPort, e.switchPort); fill(&c.linkSpeedMbps, e.linkSpeedMbps)
            fill(&c.downloadBytes, e.downloadBytes); fill(&c.uploadBytes, e.uploadBytes)
            fill(&c.downloadBps, e.downloadBps); fill(&c.uploadBps, e.uploadBps); fill(&c.uptime, e.uptime)
            out[i] = c
        }
        return out
    }
}
