// Decoders for the classic UniFi controller API (`/api/self/sites`, `/api/s/<site>/stat/device`, `stat/sta`,
// `stat/health`; prefixed with `/proxy/network` on UniFi OS). This API is undocumented by Ubiquiti but stable in shape;
// the field names below are the ones UniFi Network 6–9 return. Everything is optional, see UniFiJSON.swift.
import Foundation

public enum UniFiClassic {
    /// `/api/self/sites`: `[{ "_id", "name": "default", "desc": "Default" }]`.
    public static func sites(_ data: Data) -> [UniFiSite]? {
        UniFiJSON.records(data)?.compactMap { o in
            guard let name = o.str("name") else { return nil }
            return UniFiSite(id: name, name: name, description: o.str("desc"))
        }
    }

    /// Device type codes: ugw (USG), udm (Dream Machine), uxg (Next-Gen gateway), usw (switch), uap (access point).
    static func kind(_ type: String?) -> UniFiDeviceKind {
        switch type?.lowercased() {
        case "ugw", "udm", "uxg", "ucg", "uck": return .gateway
        case "usw": return .switch
        case "uap": return .accessPoint
        default: return .other
        }
    }

    /// Classic numeric device state.
    static func stateName(_ s: Int?) -> String? {
        guard let s else { return nil }
        switch s {
        case 0: return "disconnected"; case 1: return "connected"; case 2: return "pending adoption"
        case 4: return "upgrading"; case 5: return "provisioning"; case 6: return "heartbeat missed"
        case 7: return "adopting"; case 9: return "adoption failed"; case 10: return "isolated"
        default: return "state \(s)"
        }
    }

    /// `stat/device`.
    public static func devices(_ data: Data) -> [UniFiDevice]? {
        UniFiJSON.records(data)?.compactMap(device)
    }

    static func device(_ o: JObj) -> UniFiDevice? {
        guard let mac = o.str("mac") else { return nil }
        var d = UniFiDevice(mac: UniFi.normalizeMAC(mac), kind: kind(o.str("type")))
        d.apiID = o.str("_id"); d.name = o.str("name"); d.model = o.str("model_name") ?? o.str("model")
        d.ip = o.str("ip"); d.firmware = o.str("version"); d.uptime = o.double("uptime")
        let st = o.int("state")
        d.state = stateName(st); d.online = st.map { $0 == 1 }
        if let ss = o.obj("system-stats") { d.cpuPercent = ss.double("cpu"); d.memoryPercent = ss.double("mem") }
        d.temperatures = o.array("temperatures").compactMap { t in
            t.double("value").map { UniFiTemperature(name: t.str("name") ?? t.str("type") ?? "Sensor", celsius: $0) }
        }
        // Older switches only report one figure, and only when `has_temperature` is set.
        if d.temperatures.isEmpty, o.bool("has_temperature") != false, let g = o.double("general_temperature") {
            d.temperatures = [UniFiTemperature(name: "General", celsius: g)]
        }
        d.ports = o.array("port_table").compactMap(port)
        d.radios = radios(o)
        d.clientCount = o.int("num_sta")
        d.uplink = uplink(o)
        // Device throughput: classic rates are bytes/s; gateways and switches report it on their uplink object.
        let u = o.obj("uplink")
        d.rxBps = o.double("rx_bytes-r") ?? u?.double("rx_bytes-r")
        d.txBps = o.double("tx_bytes-r") ?? u?.double("tx_bytes-r")
        return d
    }

    static func port(_ o: JObj) -> UniFiPort? {
        guard let idx = o.int("port_idx") else { return nil }
        var p = UniFiPort(index: idx)
        p.name = o.str("name"); p.up = o.bool("up")
        // A port that's down still reports its last speed; only trust the speed while the link is up.
        p.speedMbps = p.up == false ? nil : o.int("speed").flatMap { $0 > 0 ? $0 : nil }
        p.fullDuplex = o.bool("full_duplex")
        p.poeEnabled = o.bool("poe_enable") ?? (o.str("poe_mode").map { $0 != "off" })
        p.poeWatts = o.double("poe_power")
        p.poeStandard = o.bool("port_poe") == true ? o.str("poe_caps").flatMap(poeStandard) : nil
        p.isUplink = o.bool("is_uplink")
        p.rxBytes = o.uint64("rx_bytes"); p.txBytes = o.uint64("tx_bytes")
        return p
    }

    /// `poe_caps` is a bit mask: 1 = 802.3af, 2 = 802.3at, 4 = 24 V passive, 8 = 802.3bt.
    static func poeStandard(_ caps: String) -> String? {
        guard let c = Int(caps) else { return nil }
        let names = [(8, "802.3bt"), (2, "802.3at"), (1, "802.3af"), (4, "24V passive")].filter { c & $0.0 != 0 }.map(\.1)
        return names.isEmpty ? nil : names.joined(separator: "/")
    }

    /// Radios combine `radio_table` (configuration: band, width) with `radio_table_stats` (live: channel, utilization,
    /// clients), matched by the radio's interface name ("wifi0", "wifi1"…).
    static func radios(_ o: JObj) -> [UniFiRadio] {
        let stats = Dictionary(o.array("radio_table_stats").compactMap { s in s.str("name").map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        return o.array("radio_table").map { r in
            let s = r.str("name").flatMap { stats[$0] }
            var x = UniFiRadio(band: UniFi.band(radio: r.str("radio")))
            x.channel = s?.int("channel") ?? r.int("channel")
            x.widthMHz = r.int("ht").flatMap { $0 > 0 ? $0 : nil }
            x.utilizationPercent = s?.double("cu_total")
            x.clientCount = s?.int("num_sta") ?? s?.int("user-num_sta")
            x.txPowerDbm = s?.int("tx_power")
            x.standard = r.bool("is_11be") == true ? "802.11be" : r.bool("is_11ax") == true ? "802.11ax" : r.bool("is_11ac") == true ? "802.11ac" : nil
            return x
        }
    }

    /// The device's uplink. Connected devices report `uplink`; a device that just went offline still has `last_uplink`.
    /// Gateways have an uplink of type "wire" to the WAN with no `uplink_mac`, which yields a nil parent (the root).
    static func uplink(_ o: JObj) -> UniFiUplink? {
        let u = o.obj("uplink"), last = o.obj("last_uplink")
        let mac = u?.str("uplink_mac") ?? last?.str("uplink_mac")
        guard mac != nil || u?.has("speed") == true else { return nil }
        return UniFiUplink(parentMAC: mac.map(UniFi.normalizeMAC),
                           parentPort: u?.int("uplink_remote_port") ?? last?.int("uplink_remote_port"),
                           localPort: u?.int("port_idx"),
                           speedMbps: u?.int("speed").flatMap { $0 > 0 ? $0 : nil },
                           wireless: u?.str("type").map { $0 == "wireless" })
    }

    /// `stat/sta` (currently connected clients).
    public static func clients(_ data: Data) -> [UniFiClient]? {
        UniFiJSON.records(data)?.compactMap(client)
    }

    static func client(_ o: JObj) -> UniFiClient? {
        guard let mac = o.str("mac") else { return nil }
        var c = UniFiClient(mac: UniFi.normalizeMAC(mac))
        c.apiID = o.str("_id"); c.name = o.str("name"); c.hostname = o.str("hostname")
        c.ip = o.str("ip") ?? o.str("last_ip"); c.vendor = o.str("oui")
        c.wired = o.bool("is_wired")
        if c.wired != true {
            c.apMAC = o.str("ap_mac").map(UniFi.normalizeMAC); c.ssid = o.str("essid")
            c.signalDbm = o.int("signal"); c.rssi = o.int("rssi"); c.channel = o.int("channel")
            c.wifiStandard = UniFi.wifiStandard(proto: o.str("radio_proto"))
            c.band = UniFi.band(radio: o.str("radio")) ?? UniFi.band(channel: c.channel)
            // Wi-Fi PHY rates are in kbit/s; take the slower direction as "link speed" (it's what limits throughput).
            if let tx = o.double("tx_rate"), let rx = o.double("rx_rate") { c.linkSpeedMbps = Int(min(tx, rx) / 1000) }
        }
        // Wired clients name their switch and port; newer versions add `last_uplink_mac` / `last_uplink_remote_port`.
        if c.wired != false {
            c.switchMAC = (o.str("sw_mac") ?? o.str("last_uplink_mac")).map(UniFi.normalizeMAC)
            c.switchPort = o.int("sw_port") ?? o.int("last_uplink_remote_port")
            c.linkSpeedMbps = c.linkSpeedMbps ?? o.int("wired_rate_mbps")
        }
        // Counters are from the network's side: `tx_bytes` is what the AP/switch sent to the client (its download),
        // `rx_bytes` what it received from the client (its upload). The UniFi UI shows them the same way round.
        let w = c.wired == true ? "wired-" : ""
        c.downloadBytes = o.uint64(w + "tx_bytes") ?? o.uint64("tx_bytes")
        c.uploadBytes = o.uint64(w + "rx_bytes") ?? o.uint64("rx_bytes")
        c.downloadBps = o.double(w + "tx_bytes-r") ?? o.double("tx_bytes-r")
        c.uploadBps = o.double(w + "rx_bytes-r") ?? o.double("rx_bytes-r")
        c.uptime = o.double("uptime")
        return c
    }

    /// `stat/health`: one record per subsystem ("wan", "www", "wlan", "lan", "vpn").
    public static func health(_ data: Data) -> UniFiHealth? {
        guard let recs = UniFiJSON.records(data) else { return nil }
        var h = UniFiHealth()
        for r in recs {
            guard let sub = r.str("subsystem") else { continue }
            if let s = r.str("status") { h.subsystems[sub] = s }
            switch sub {
            case "wan":
                h.wanIP = r.str("wan_ip"); h.isp = r.str("isp_name") ?? r.str("isp_organization")
                h.wanRxBps = r.double("rx_bytes-r"); h.wanTxBps = r.double("tx_bytes-r")
                // Newer consoles monitor WAN availability and latency against a few targets.
                if let w = r.obj("uptime_stats")?.obj("WAN") {
                    h.latencyMs = h.latencyMs ?? w.double("latency_average")
                    h.wanUptime = h.wanUptime ?? w.double("uptime")
                }
                h.packetLossPercent = r.double("packet_loss") ?? h.packetLossPercent
            case "www":
                // "www" is the internet check: latency to the test host, uptime, drops and the last speed test.
                h.latencyMs = r.double("latency") ?? h.latencyMs
                h.wanUptime = r.double("uptime") ?? h.wanUptime
                let down = r.double("xput_down"), up = r.double("xput_up")
                if (down ?? 0) > 0 || (up ?? 0) > 0 {
                    h.speedTest = UniFiSpeedTest(downloadMbps: down, uploadMbps: up, latencyMs: r.double("speedtest_ping"),
                                                 time: r.double("speedtest_lastrun").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
                }
            default: break
            }
        }
        return h
    }
}
