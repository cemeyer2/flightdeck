// Decoders for the official UniFi Network Integration API (`/proxy/network/integration/v1/...` on UniFi OS, authenticated
// with an `X-API-KEY` header). Shapes follow Ubiquiti's published API reference (Network application 9.x):
//   GET sites                                   → { offset, limit, count, totalCount, data: [{ id, internalReference, name }] }
//   GET sites/{site}/devices                    → data: [{ id, name, model, macAddress, ipAddress, state, features, interfaces }]
//   GET sites/{site}/devices/{id}               → … + firmwareVersion, uplink { deviceId }, interfaces { ports, radios }
//   GET sites/{site}/devices/{id}/statistics/latest → { uptimeSec, cpuUtilizationPct, memoryUtilizationPct, uplink { txRateBps, rxRateBps } }
//   GET sites/{site}/clients                    → data: [{ type, id, name, connectedAt, ipAddress, macAddress, uplinkDeviceId }]
// The integration API names the client's AP or switch but not the switch port, signal or traffic; the classic API
// fills those in when the console accepts the same key there (see UniFiClient).
import Foundation

public enum UniFiIntegration {
    public static func sites(_ data: Data) -> [UniFiSite]? {
        UniFiJSON.records(data)?.compactMap { o in
            guard let id = o.str("id") else { return nil }
            return UniFiSite(id: id, name: o.str("internalReference"), description: o.str("name"))
        }
    }

    /// Model prefixes of UniFi gateways and consoles that route (Dream Machine/Router, Cloud Gateway, Next-Gen and
    /// Security Gateways, Enterprise Fortress Gateway). The list endpoint has no explicit "gateway" feature.
    static let gatewayModels = ["UDM", "UDR", "UCG", "UXG", "USG", "UDW", "EFG", "UX", "Dream", "Cloud Gateway", "Gateway"]

    static func kind(model: String?, features: [String]) -> UniFiDeviceKind {
        let f = Set(features.map { $0.lowercased() })
        if let m = model, gatewayModels.contains(where: { m.hasPrefix($0) }) { return .gateway }
        if f.contains("gateway") { return .gateway }
        if f.contains("accesspoint") { return .accessPoint }
        if f.contains("switching") { return .switch }
        return .other
    }

    /// `features` is an array of names in the list endpoint and an object keyed by name in the detail endpoint.
    static func featureNames(_ o: JObj) -> [String] {
        if let a = o.raw["features"] as? [String] { return a }
        if let d = o.raw["features"] as? [String: Any] { return Array(d.keys) }
        return []
    }

    /// One device from the list or the detail endpoint (the detail adds firmware, uplink, ports and radios).
    static func device(_ o: JObj) -> UniFiDevice? {
        guard let mac = o.str("macAddress") else { return nil }
        var d = UniFiDevice(mac: UniFi.normalizeMAC(mac), kind: kind(model: o.str("model"), features: featureNames(o)))
        d.apiID = o.str("id"); d.name = o.str("name"); d.model = o.str("model"); d.ip = o.str("ipAddress")
        d.firmware = o.str("firmwareVersion")
        d.state = o.str("state"); d.online = d.state.map { $0.uppercased() == "ONLINE" }
        if let ifs = o.obj("interfaces") {
            d.ports = ifs.array("ports").compactMap { p in
                guard let idx = p.int("idx") else { return nil }
                var x = UniFiPort(index: idx)
                x.up = p.str("state").map { $0.uppercased() == "UP" }
                x.speedMbps = x.up == false ? nil : p.int("speedMbps").flatMap { $0 > 0 ? $0 : nil }
                x.maxSpeedMbps = p.int("maxSpeedMbps")
                if let poe = p.obj("poe") { x.poeEnabled = poe.bool("enabled"); x.poeStandard = poe.str("standard") }
                return x
            }
            d.radios = ifs.array("radios").map { r in
                var x = UniFiRadio(band: r.double("frequencyGHz").map { $0 < 3 ? "2.4 GHz" : $0 < 5.9 ? "5 GHz" : "6 GHz" })
                x.channel = r.int("channel"); x.widthMHz = r.int("channelWidthMHz"); x.standard = r.str("wlanStandard")
                return x
            }
        }
        return d
    }

    public static func devices(_ data: Data) -> [UniFiDevice]? { UniFiJSON.records(data)?.compactMap(device) }

    /// Detail endpoint: the device plus the integration ID of its uplink device (resolved to a MAC by `resolve`).
    public static func deviceDetail(_ data: Data) -> (device: UniFiDevice, uplinkDeviceID: String?)? {
        guard let o = UniFiJSON.object(data), let d = device(o) else { return nil }
        return (d, o.obj("uplink")?.str("deviceId"))
    }

    /// Applies `statistics/latest` to a device.
    public static func applyStatistics(_ data: Data, to d: inout UniFiDevice) {
        guard let o = UniFiJSON.object(data) else { return }
        d.uptime = o.double("uptimeSec") ?? d.uptime
        d.cpuPercent = o.double("cpuUtilizationPct") ?? d.cpuPercent
        d.memoryPercent = o.double("memoryUtilizationPct") ?? d.memoryPercent
        // The reference calls these "rate Bps"; we read them as bits per second (the integration API's other speeds
        // are in bits too) and store bytes per second like the classic API.
        if let u = o.obj("uplink") {
            d.txBps = u.double("txRateBps").map { $0 / 8 } ?? d.txBps
            d.rxBps = u.double("rxRateBps").map { $0 / 8 } ?? d.rxBps
        }
    }

    /// Clients. `uplinkDeviceId` is an integration device ID; `resolve` turns it into an AP or switch MAC.
    public static func clients(_ data: Data) -> [UniFiClient]? {
        UniFiJSON.records(data)?.compactMap { o in
            guard let mac = o.str("macAddress") else { return nil }
            var c = UniFiClient(mac: UniFi.normalizeMAC(mac))
            c.apiID = o.str("id"); c.name = o.str("name"); c.ip = o.str("ipAddress")
            switch o.str("type")?.uppercased() {
            case "WIRED": c.wired = true
            case "WIRELESS": c.wired = false
            default: c.wired = nil   // VPN, TELEPORT or unknown
            }
            c.uplinkDeviceID = o.str("uplinkDeviceId")
            if let s = o.str("connectedAt"), let t = ISO8601DateFormatter().date(from: s) { c.uptime = max(0, Date().timeIntervalSince(t)) }
            return c
        }
    }

    /// Resolves integration device IDs into MACs: each device's uplink parent and each client's AP or switch.
    public static func resolve(devices: inout [UniFiDevice], uplinkIDs: [String: String], clients: inout [UniFiClient]) {
        let macByID = Dictionary(devices.compactMap { d in d.apiID.map { ($0, d.mac) } }, uniquingKeysWith: { a, _ in a })
        for i in devices.indices {
            if let up = devices[i].apiID.flatMap({ uplinkIDs[$0] }), let parent = macByID[up] {
                var u = devices[i].uplink ?? UniFiUplink(); u.parentMAC = parent; devices[i].uplink = u
            }
        }
        for i in clients.indices {
            guard let parent = clients[i].uplinkDeviceID.flatMap({ macByID[$0] }) else { continue }
            let kind = devices.first { $0.mac == parent }?.kind
            if clients[i].wired == false || (clients[i].wired == nil && kind == .accessPoint) { clients[i].apMAC = parent }
            else { clients[i].switchMAC = parent }
        }
    }
}
