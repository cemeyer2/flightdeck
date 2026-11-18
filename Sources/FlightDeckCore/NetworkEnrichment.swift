import Foundation

// Joins the Network map's own discovery with what the UPnP scan and a configured UniFi console know.
//
// The map sees devices from this Mac's point of view (ARP/NDP, Bonjour, reverse DNS), which can't tell how anything is
// physically connected and is often missing devices macOS hides from it. UPnP adds friendly names, manufacturers and
// models (matched by IP address). A UniFi console adds what only the network itself knows (matched by MAC): the name
// the user gave each client, and which access point or switch port it's on. Devices the console knows but this Mac
// didn't see are added, marked as coming from UniFi. Nothing here does I/O; it's a pure merge so it can be tested.

public enum NetworkEnrichment {
    /// `upnp` and `unifi` are optional: whichever is available is applied. The survey's notes say what was used.
    public static func apply(_ survey: NetworkSurvey, upnp: [UPnPHostInfo] = [], unifi: UniFiSnapshot? = nil) -> NetworkSurvey {
        var s = survey
        if !upnp.isEmpty { applyUPnP(&s, upnp) }
        if let unifi { applyUniFi(&s, unifi) }
        return s
    }

    // MARK: UPnP

    static func applyUPnP(_ s: inout NetworkSurvey, _ hosts: [UPnPHostInfo]) {
        // One IP can run several root devices (a TV's renderer and its DIAL server); the first with a name wins.
        var byIP: [String: UPnPHostInfo] = [:]
        for h in hosts where byIP[h.ip]?.friendlyName == nil { byIP[h.ip] = h }
        var matched = 0
        for i in s.devices.indices {
            guard let h = s.devices[i].ipv4.lazy.compactMap({ byIP[$0] }).first else { continue }
            matched += 1
            var d = s.devices[i]
            d.upnpName = d.upnpName ?? h.friendlyName
            d.manufacturer = d.manufacturer ?? h.manufacturer
            d.model = d.model ?? h.model
            if let t = h.deviceType, !d.services.contains(t) { d.services.append(t) }
            if !d.sources.contains("UPnP") { d.sources.append("UPnP") }
            // Re-guess with the new facts unless the device was already identified more firmly (this Mac, the router).
            if !d.isThisMac && !d.isGateway {
                let g = DeviceClassifier.guess(d)
                if g.kind != .unknown { (d.kind, d.kindReason) = g }
                else if let k = kind(of: h.category) { d.kind = k; d.kindReason = "announces itself over UPnP as one of \(h.category.rawValue.lowercased())" }
            }
            s.devices[i] = d
        }
        if matched > 0 { s.notes.append("Names and models for \(matched) device\(matched == 1 ? "" : "s") came from UPnP.") }
    }

    static func kind(of c: UPnPCategory) -> DeviceKind? {
        switch c {
        case .gateway: .router
        case .mediaRenderer: .tv          // renderers are mostly TVs and streamers; speakers are caught by name/vendor first
        case .mediaServer: .nas
        case .printer: .printer
        case .other: nil
        }
    }

    // MARK: UniFi

    static func applyUniFi(_ s: inout NetworkSurvey, _ u: UniFiSnapshot) {
        var index: [String: Int] = [:]
        for (i, d) in s.devices.enumerated() { if let m = d.mac { index[m] = i } }
        var attached = 0, added = 0
        func merge(mac raw: String, name: String?, ip: String?, isInfra: Bool, model: String?) {
            guard let mac = MAC.normalize(raw) else { return }
            var d: NetDevice
            let existing = index[mac]
            if let existing { d = s.devices[existing] } else {
                // Seen by the console but not by this Mac (other VLAN, asleep, or hidden by macOS's Local Network rules).
                d = NetDevice(id: "mac:\(mac)"); d.mac = mac
                d.vendor = OUI.lookup(mac)
                if let ip, !ip.isEmpty { d.ipv4 = [ip] }
                d.firstSeen = u.time; d.lastSeen = u.time
                added += 1
            }
            if let name, !name.isEmpty { d.unifiName = name }
            if d.model == nil, let model { d.model = model }
            if let a = u.attachment(ofMAC: mac) { d.attachment = describe(a); attached += 1 }
            if !d.sources.contains("UniFi") { d.sources.append("UniFi") }
            if isInfra && !d.isGateway && !d.isThisMac { d.kind = .networkGear; d.kindReason = "a UniFi \(model ?? "device") managed by the console" }
            else if !d.isThisMac && !d.isGateway && d.kind == .unknown { (d.kind, d.kindReason) = DeviceClassifier.guess(d) }
            if let existing { s.devices[existing] = d } else { index[mac] = s.devices.count; s.devices.append(d) }
        }
        for dev in u.devices { merge(mac: dev.mac, name: dev.name, ip: dev.ip, isInfra: true, model: dev.model) }
        for c in u.clients { merge(mac: c.mac, name: c.name ?? c.hostname, ip: c.ip, isInfra: false, model: nil) }
        var note = "UniFi console: \(attached) device\(attached == 1 ? "" : "s") placed on their access point or switch port"
        if added > 0 { note += ", \(added) added that this Mac couldn't see" }
        s.notes.append(note + ".")
    }

    /// "Wi-Fi via Office AP (Home) · 866 Mbps" / "Rack Switch port 5 · 1 Gbps".
    static func describe(_ a: UniFiAttachment) -> String {
        var t: String
        switch a.link {
        case .wireless(let ssid): t = "Wi-Fi via \(a.deviceName)" + (ssid.map { " (\($0))" } ?? "")
        case .wired(let port): t = port.map { "\(a.deviceName) port \($0)" } ?? "wired to \(a.deviceName)"
        case .unknown: t = "on \(a.deviceName)"
        }
        if let mbps = a.speedMbps, mbps > 0 { t += mbps >= 1000 && mbps % 1000 == 0 ? " · \(mbps / 1000) Gbps" : " · \(mbps) Mbps" }
        return t
    }
}
