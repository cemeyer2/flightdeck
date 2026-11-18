// An invented UniFi network for demo mode (`-demo YES`) and headless renders: a gateway, a PoE switch, two APs and a
// dozen clients. All MACs are locally administered (02:…), so they can't belong to real hardware; the IPs are private
// and the WAN address is from the documentation range (203.0.113.0/24). No network calls are made.
import Foundation
import FlightDeckCore

enum UniFiDemo {
    static let gw = "02:ac:00:00:00:01", sw = "02:ac:00:00:00:02", apLiving = "02:ac:00:00:00:03", apOffice = "02:ac:00:00:00:04"

    /// Deterministic wobble so rates move between polls without randomness.
    static func w(_ tick: Int, _ seed: Double, _ amount: Double = 0.3) -> Double {
        1 + amount * sin(Double(tick) * 0.9 + seed * 1.7) * cos(Double(tick) * 0.37 + seed)
    }

    static func snapshot(tick: Int = 0, now: Date = Date()) -> UniFiSnapshot {
        var s = UniFiSnapshot(time: now, source: .demo)
        let site = UniFiSite(id: "default", name: "default", description: "Home")
        s.site = site; s.sites = [site]

        var g = UniFiDevice(mac: gw, kind: .gateway)
        g.name = "Gateway"; g.model = "UCG Ultra"; g.ip = "203.0.113.24"; g.firmware = "4.1.13"; g.uptime = 1_843_200
        g.state = "connected"; g.online = true; g.cpuPercent = 14 * w(tick, 1); g.memoryPercent = 58
        g.temperatures = [UniFiTemperature(name: "CPU", celsius: 57 * w(tick, 2, 0.03))]
        g.ports = (1...5).map { i in
            var p = UniFiPort(index: i); p.name = i == 5 ? "WAN" : "Port \(i)"; p.up = i == 1 || i == 5
            p.speedMbps = p.up == true ? (i == 5 ? 2500 : 2500) : nil; p.isUplink = i == 5; return p
        }
        g.clientCount = 12
        var sw1 = UniFiDevice(mac: sw, kind: .switch)
        sw1.name = "Office Switch"; sw1.model = "USW Lite 8 PoE"; sw1.ip = "10.0.0.2"; sw1.firmware = "7.1.26"; sw1.uptime = 1_209_000
        sw1.state = "connected"; sw1.online = true; sw1.cpuPercent = 6 * w(tick, 3); sw1.memoryPercent = 41
        sw1.temperatures = [UniFiTemperature(name: "General", celsius: 43)]
        sw1.uplink = UniFiUplink(parentMAC: gw, parentPort: 1, localPort: 8, speedMbps: 1000, wireless: false)
        let swPorts: [(Int, String?, Int?, Double?)] = [(1, "AP Living Room", 1000, 9.6), (2, "AP Office", 1000, 6.1), (3, "NAS", 1000, nil),
                                                       (4, "Desk", 1000, nil), (5, "TV", 100, nil), (6, nil, nil, nil), (7, nil, nil, nil), (8, "Uplink", 1000, nil)]
        sw1.ports = swPorts.map { i, name, speed, poe in
            var p = UniFiPort(index: i); p.name = name; p.up = speed != nil; p.speedMbps = speed; p.fullDuplex = speed != nil
            p.poeEnabled = i <= 4; p.poeWatts = poe; p.poeStandard = i <= 4 ? "802.3at" : nil; p.isUplink = i == 8; return p
        }
        func ap(_ mac: String, _ name: String, _ model: String, _ ip: String, port: Int, ch24: Int, ch5: Int, cu: (Double, Double), n: (Int, Int)) -> UniFiDevice {
            var a = UniFiDevice(mac: mac, kind: .accessPoint)
            a.name = name; a.model = model; a.ip = ip; a.firmware = "7.0.66"; a.uptime = 604_800; a.state = "connected"; a.online = true
            a.cpuPercent = 9 * w(tick, Double(port)); a.memoryPercent = 47; a.clientCount = n.0 + n.1
            a.uplink = UniFiUplink(parentMAC: sw, parentPort: port, localPort: 1, speedMbps: 1000, wireless: false)
            var r1 = UniFiRadio(band: "2.4 GHz"); r1.channel = ch24; r1.widthMHz = 20; r1.utilizationPercent = cu.0 * w(tick, 4, 0.15); r1.clientCount = n.0; r1.txPowerDbm = 14; r1.standard = "802.11ax"
            var r2 = UniFiRadio(band: "5 GHz"); r2.channel = ch5; r2.widthMHz = 80; r2.utilizationPercent = cu.1 * w(tick, 5, 0.2); r2.clientCount = n.1; r2.txPowerDbm = 20; r2.standard = "802.11ax"
            a.radios = [r1, r2]
            return a
        }
        s.devices = [g, sw1,
                     ap(apLiving, "Living Room AP", "U7 Pro", "10.0.0.3", port: 1, ch24: 6, ch5: 36, cu: (42, 18), n: (3, 4)),
                     ap(apOffice, "Office AP", "U6 Lite", "10.0.0.4", port: 2, ch24: 11, ch5: 149, cu: (27, 9), n: (1, 1))]

        func wifi(_ i: Int, _ host: String, _ vendor: String, ap: String, ssid: String, signal: Int, ch: Int, std: String, down: Double, up: Double, phy: Int) -> UniFiClient {
            var c = UniFiClient(mac: String(format: "02:dc:00:00:00:%02x", i))
            c.hostname = host; c.ip = "10.0.0.\(100 + i)"; c.vendor = vendor; c.wired = false; c.apMAC = ap; c.ssid = ssid
            c.signalDbm = signal; c.rssi = signal + 96; c.channel = ch; c.band = UniFi.band(channel: ch); c.wifiStandard = std; c.linkSpeedMbps = phy
            c.downloadBps = down * w(tick, Double(i)); c.uploadBps = up * w(tick, Double(i) + 0.5)
            c.downloadBytes = UInt64(down * 3600 * 5); c.uploadBytes = UInt64(up * 3600 * 5); c.uptime = Double(3600 * (i + 2))
            return c
        }
        func wired(_ i: Int, _ host: String, _ vendor: String, port: Int, speed: Int, down: Double, up: Double) -> UniFiClient {
            var c = UniFiClient(mac: String(format: "02:dc:00:00:00:%02x", i))
            c.hostname = host; c.ip = "10.0.0.\(100 + i)"; c.vendor = vendor; c.wired = true; c.switchMAC = sw; c.switchPort = port; c.linkSpeedMbps = speed
            c.downloadBps = down * w(tick, Double(i)); c.uploadBps = up * w(tick, Double(i) + 0.5)
            c.downloadBytes = UInt64(down * 86_400); c.uploadBytes = UInt64(up * 86_400); c.uptime = 1_000_000
            return c
        }
        let ax = "802.11ax (Wi-Fi 6/6E)", ac = "802.11ac (Wi-Fi 5)", n = "802.11n (Wi-Fi 4)"
        s.clients = [
            wifi(1, "Demo-MacBook-Pro", "Apple", ap: apLiving, ssid: "Home", signal: -52, ch: 36, std: ax, down: 2_400_000, up: 310_000, phy: 1201),
            wifi(2, "iPhone", "Apple", ap: apLiving, ssid: "Home", signal: -61, ch: 36, std: ax, down: 180_000, up: 22_000, phy: 864),
            wifi(3, "iPad", "Apple", ap: apLiving, ssid: "Home", signal: -66, ch: 36, std: ax, down: 950_000, up: 15_000, phy: 573),
            wifi(4, "living-room-tv", "Samsung", ap: apLiving, ssid: "Home", signal: -58, ch: 36, std: ac, down: 3_100_000, up: 40_000, phy: 433),
            wifi(5, "thermostat", "Ecobee", ap: apLiving, ssid: "IoT", signal: -71, ch: 6, std: n, down: 400, up: 900, phy: 65),
            wifi(6, "doorbell", "Ring", ap: apLiving, ssid: "IoT", signal: -79, ch: 6, std: n, down: 6_000, up: 210_000, phy: 39),
            wifi(7, "speaker-kitchen", "Sonos", ap: apLiving, ssid: "Home", signal: -63, ch: 6, std: n, down: 42_000, up: 2_000, phy: 72),
            wifi(8, "work-laptop", "Dell", ap: apOffice, ssid: "Home", signal: -55, ch: 149, std: ax, down: 620_000, up: 480_000, phy: 1201),
            wifi(9, "printer", "Brother", ap: apOffice, ssid: "IoT", signal: -68, ch: 11, std: n, down: 300, up: 200, phy: 58),
            wired(10, "nas", "Synology", port: 3, speed: 1000, down: 120_000, up: 1_900_000),
            wired(11, "desk-pc", "ASUSTek", port: 4, speed: 1000, down: 760_000, up: 95_000),
            wired(12, "tv-box", "Apple", port: 5, speed: 100, down: 1_200_000, up: 18_000),
        ]
        var h = UniFiHealth()
        h.wanIP = "203.0.113.24"; h.isp = "Example Fiber"
        let rx = s.clients.compactMap(\.downloadBps).reduce(0, +), tx = s.clients.compactMap(\.uploadBps).reduce(0, +)
        h.wanRxBps = rx * 0.9; h.wanTxBps = tx * 0.6
        h.latencyMs = 9 * w(tick, 7, 0.25); h.packetLossPercent = 0; h.wanUptime = 1_843_000
        h.subsystems = ["wan": "ok", "www": "ok", "lan": "ok", "wlan": "ok"]
        h.speedTest = UniFiSpeedTest(downloadMbps: 938.4, uploadMbps: 912.7, latencyMs: 4, time: now.addingTimeInterval(-5 * 3600))
        s.health = h
        g.rxBps = h.wanRxBps; g.txBps = h.wanTxBps; s.devices[0] = g
        return s
    }
}
