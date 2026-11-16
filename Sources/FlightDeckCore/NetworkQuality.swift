import Foundation
import CoreWLAN

// Network quality: current Wi-Fi link details (CoreWLAN, refreshed every 5 s by Sampler), default route and DNS
// servers, and the opt-in ping-based latency probe.
/// The associated Wi-Fi link as reported by CoreWLAN for the default Wi-Fi interface. Optional fields are nil when
/// CoreWLAN doesn't report them or reports a value this code doesn't name.
public struct WiFiInfo: Codable, Sendable, Hashable {
    public var interface: String
    public var ssid: String?            // nil unless the app has Location permission
    public var rssi: Int                // dBm
    public var noise: Int               // dBm
    public var txRate: Double           // Mbps
    public var channel: Int?
    public var band: String?            // 2.4 / 5 / 6 GHz
    public var width: String?           // 20/40/80/160 MHz
    public var phy: String?             // 802.11ax ...
    public var security: String?
    /// Signal-to-noise ratio in dB.
    public var snr: Int { rssi - noise }
    /// Plain-English signal quality.
    public var quality: String {
        switch rssi {
        // RSSI bands in dBm, using the usual Wi-Fi rules of thumb (around -67 dBm is the floor for reliable real-time use).
        case (-55)...: return "Excellent"
        case (-67)...: return "Good"
        case (-75)...: return "Fair"
        default: return "Poor"
        }
    }

    /// nil when there's no Wi-Fi interface, it is off, or it isn't associated (CoreWLAN reports RSSI 0 then). The SSID needs
    /// Location Services permission on modern macOS, so it is nil otherwise even while connected.
    public static func current() -> WiFiInfo? {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn(), i.rssiValue() != 0 else { return nil }
        let ch = i.wlanChannel()
        let band: String? = ch.map { c in
            switch c.channelBand { case .band2GHz: "2.4 GHz"; case .band5GHz: "5 GHz"; case .band6GHz: "6 GHz"; default: "?" }
        }
        let width: String? = ch.map { c in
            switch c.channelWidth { case .width20MHz: "20 MHz"; case .width40MHz: "40 MHz"; case .width80MHz: "80 MHz"; case .width160MHz: "160 MHz"; default: "?" }
        }
        let phy: String? = {
            switch i.activePHYMode() {
            case .mode11a: "802.11a"; case .mode11b: "802.11b"; case .mode11g: "802.11g"; case .mode11n: "802.11n (Wi-Fi 4)"
            case .mode11ac: "802.11ac (Wi-Fi 5)"; case .mode11ax: "802.11ax (Wi-Fi 6/6E)"
            default: nil
            }
        }()
        let sec: String? = {
            switch i.security() {
            case .none: "Open"; case .WEP: "WEP"; case .wpaPersonal, .wpaPersonalMixed: "WPA"; case .wpa2Personal: "WPA2"
            case .personal: "WPA2/WPA3"; case .wpa3Personal: "WPA3"; case .wpa3Transition: "WPA2/WPA3"
            case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise, .wpa3Enterprise: "Enterprise"
            default: nil
            }
        }()
        return WiFiInfo(interface: i.interfaceName ?? "en0", ssid: i.ssid(), rssi: i.rssiValue(), noise: i.noiseMeasurement(),
                        txRate: i.transmitRate(), channel: ch?.channelNumber, band: band, width: width, phy: phy, security: sec)
    }
}

/// One ping burst's summary for one target. Times are ms. `jitterMs` is ping's reported standard deviation of the
/// round-trip times.
public struct LatencyResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String { role }
    public var role: String             // "Router" or "Internet"
    public var host: String
    public var avgMs: Double?           // nil when every probe was lost
    public var jitterMs: Double?
    public var loss: Double             // 0...100 %
    public var time: Date
}

/// Routing and DNS facts read from command-line tools / config files, for the network views.
public enum NetworkConfig {
    /// Default route's gateway and interface, from the routing table.
    /// Parses `route -n get default` ("gateway:" / "interface:" lines; -n avoids reverse DNS). nil if there is no
    /// default route (offline) or the output lacks either field.
    public static func defaultRoute() -> (gateway: String, interface: String)? {
        guard let out = Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 3) else { return nil }
        var gw: String?, ifc: String?
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") { gw = t.dropFirst(8).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("interface:") { ifc = t.dropFirst(10).trimmingCharacters(in: .whitespaces) }
        }
        guard let gw, let ifc else { return nil }
        return (gw, ifc)
    }

    /// "nameserver" entries from /etc/resolv.conf, which macOS generates from the primary resolver configuration (it does
    /// not include per-domain or VPN-scoped resolvers). Empty if the file is missing.
    public static func dnsServers() -> [String] {
        guard let s = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { l in
            let parts = l.split(separator: " ")
            return parts.count >= 2 && parts[0] == "nameserver" ? String(parts[1]) : nil
        }
    }
}

/// Opt-in latency / packet-loss probe using the system `ping`: a burst of 5 pings to the router and to an
/// internet host every `period` seconds. Nothing runs unless `start()` is called.
/// Thread-safety: `_results` and `timer` are guarded by `lock`; probing runs on a private utility queue. Results are
/// read by Sampler and attached to each snapshot.
public final class NetworkProbe: @unchecked Sendable {
    /// Target for the "Internet" row. Not lock-protected; set before start().
    public var internetHost: String
    /// Seconds between bursts.
    public let period: TimeInterval
    private let lock = NSLock()
    private var _results: [LatencyResult] = []
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "flightdeck.netprobe", qos: .utility)

    public init(internetHost: String = "1.1.1.1", period: TimeInterval = 10) { self.internetHost = internetHost; self.period = period }

    public var results: [LatencyResult] { lock.lock(); defer { lock.unlock() }; return _results }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return timer != nil }

    /// Starts probing immediately and then every `period` seconds. Idempotent.
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: period)
        t.setEventHandler { [weak self] in self?.probe() }
        t.resume(); timer = t
    }

    /// Stops probing and clears results, so snapshots stop carrying stale latency.
    public func stop() {
        lock.lock(); timer?.cancel(); timer = nil; _results = []; lock.unlock()
    }

    /// One round: router (default gateway) then internet host. A target whose ping couldn't run or parse is omitted.
    /// If stop() raced with an in-flight round, the result is discarded.
    private func probe() {
        var out: [LatencyResult] = []
        if let gw = NetworkConfig.defaultRoute()?.gateway, let r = Self.ping(gw, role: "Router") { out.append(r) }
        if let r = Self.ping(internetHost, role: "Internet") { out.append(r) }
        lock.lock(); if timer != nil { _results = out }; lock.unlock()
    }

    /// `count` pings 0.2 s apart, the whole run capped at 4 s (-t), quiet summary only (-q). Shell.run kills ping
    /// after 6 s. ping exits non-zero on loss, but its summary is still parsed.
    public static func ping(_ host: String, role: String, count: Int = 5) -> LatencyResult? {
        guard let out = Shell.run("/sbin/ping", ["-c", "\(count)", "-i", "0.2", "-t", "4", "-q", host], timeout: 6) else { return nil }
        return parse(out, host: host, role: role)
    }

    /// Extracts "N% packet loss" and the "min/avg/max/stddev" round-trip line. With 100% loss there is no round-trip line,
    /// so avg/jitter stay nil while loss is 100. nil if no loss line was found (ping failed to resolve or run).
    static func parse(_ out: String, host: String, role: String) -> LatencyResult? {
        var loss: Double?
        var avg: Double?, jitter: Double?
        for line in out.split(separator: "\n") {
            if line.contains("packet loss"), let r = line.range(of: #"([\d.]+)% packet loss"#, options: .regularExpression) {
                loss = Double(line[r].split(separator: "%")[0])
            }
            if line.contains("min/avg/max"), let eq = line.split(separator: "=").last {
                let nums = eq.trimmingCharacters(in: .whitespaces).split(separator: " ")[0].split(separator: "/").compactMap { Double($0) }
                if nums.count >= 4 { avg = nums[1]; jitter = nums[3] }
            }
        }
        guard let loss else { return nil }
        return LatencyResult(role: role, host: host, avgMs: avg, jitterMs: jitter, loss: loss, time: Date())
    }
}
