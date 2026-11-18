import Foundation

// Internet speed and responsiveness test: the result model and a tolerant parser for the JSON that macOS's own
// `/usr/bin/networkQuality -c` prints. Running it lives in SpeedTestRunner.swift; plain-English verdicts in
// SpeedTestVerdict.swift. networkQuality measures against Apple's CDN test servers (the same test as System
// Information's "Network quality"), so FlightDeck adds no server of its own.

/// What the rest of the network looked like when a test started, so a result can be compared with the Wi-Fi link
/// and the latency probe. Every field is nil when that source wasn't available (wired, Wi-Fi off, probe off).
public struct SpeedTestContext: Codable, Sendable, Hashable {
    public var wifiRSSI: Int?
    public var wifiNoise: Int?
    /// Wi-Fi PHY (link) rate, Mbps: the raw rate the radio negotiated, not achievable throughput.
    public var wifiTxRate: Double?
    public var wifiPHY: String?
    public var wifiBand: String?
    /// Latency probe results (Settings › Network) at test start; nil when the probe was off.
    public var routerMs: Double?
    public var routerLoss: Double?
    public var internetMs: Double?
    public var internetLoss: Double?
    public init(wifi: WiFiInfo? = nil, latency: [LatencyResult]? = nil) {
        wifiRSSI = wifi?.rssi; wifiNoise = wifi?.noise; wifiTxRate = wifi.map(\.txRate); wifiPHY = wifi?.phy; wifiBand = wifi?.band
        let r = latency?.first { $0.role == "Router" }, i = latency?.first { $0.role == "Internet" }
        routerMs = r?.avgMs; routerLoss = r?.loss; internetMs = i?.avgMs; internetLoss = i?.loss
    }
}

/// One networkQuality run. Throughputs are Mbps (networkQuality reports bits/s); latencies ms. Any field
/// networkQuality didn't report stays nil: older macOS versions print fewer fields, and sequential mode reports
/// per-direction responsiveness instead of one figure.
public struct SpeedTestResult: Codable, Sendable, Hashable, Identifiable {
    public var id: Date { time }
    /// When the test finished.
    public var time: Date
    public var downloadMbps: Double?
    public var uploadMbps: Double?
    /// Round trips per minute while the link is fully loaded (higher is better). 60 000 / RPM = working latency in ms.
    public var responsivenessRPM: Double?
    /// Idle round-trip time to the test server, ms ("base_rtt").
    public var baseRTTms: Double?
    public var interface: String?
    /// "wifi", "wiredethernet", "cellular"…: networkQuality's own label for the interface it used.
    public var interfaceType: String?
    public var endpoint: String?
    public var downloadBytes: UInt64?
    public var uploadBytes: UInt64?
    /// true when the opt-in schedule started it (not the button).
    public var scheduled = false
    public var context: SpeedTestContext?

    public init(time: Date) { self.time = time }

    /// Latency while the link is saturated, derived from RPM (a round trip per 60 000 / RPM ms).
    public var loadedLatencyMs: Double? { responsivenessRPM.flatMap { $0 > 0 ? 60_000 / $0 : nil } }
    /// How much loading the link adds to latency: the bufferbloat figure.
    public var latencyIncreaseMs: Double? {
        guard let l = loadedLatencyMs, let b = baseRTTms else { return nil }
        return max(0, l - b)
    }
}

public enum SpeedTestError: Error, Equatable, CustomStringConvertible {
    /// Output wasn't a JSON object (networkQuality missing, killed, or printed a plain-text error).
    case notJSON(String)
    /// networkQuality ran and reported an error (offline, server unreachable…).
    case reported(String)
    /// JSON without any measurement in it.
    case noMeasurements
    case timedOut
    case cancelled
    case unavailable(String)

    public var description: String {
        switch self {
        case .notJSON(let s): return s.isEmpty ? "networkQuality produced no output" : "networkQuality said: \(s)"
        case .reported(let s): return "networkQuality reported an error: \(s)"
        case .noMeasurements: return "networkQuality finished without measuring anything"
        case .timedOut: return "the test took too long and was stopped"
        case .cancelled: return "cancelled"
        case .unavailable(let s): return s
        }
    }
}

public enum SpeedTest {
    /// Parses `networkQuality -c` output. Field names have changed across macOS releases, so each value is looked up
    /// under every name it is known to have had, and numbers are accepted as JSON numbers or numeric strings.
    /// Throughputs arrive in bits per second. Throws when there is nothing to show; a partial result (say, upload
    /// skipped) is returned with the missing fields nil.
    public static func parse(_ data: Data, time: Date = Date()) throws -> SpeedTestResult {
        guard let obj = try? JSONSerialization.jsonObject(with: data), let j = obj as? [String: Any] else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SpeedTestError.notJSON(String(text.prefix(200)))
        }
        var r = SpeedTestResult(time: time)
        r.downloadMbps = number(j, ["dl_throughput", "downlink_throughput", "download_throughput"]).map { $0 / 1e6 }
        r.uploadMbps = number(j, ["ul_throughput", "uplink_throughput", "upload_throughput"]).map { $0 / 1e6 }
        // Parallel mode (the default) reports one "responsiveness"; sequential mode reports one per direction, of
        // which the lower (worse) one is what a call would feel.
        let perDirection = [number(j, ["dl_responsiveness"]), number(j, ["ul_responsiveness"])].compactMap { $0 }
        r.responsivenessRPM = number(j, ["responsiveness", "rpm"]) ?? perDirection.min()
        r.baseRTTms = number(j, ["base_rtt", "base_rtt_ms", "idle_latency_ms"])
        r.interface = j["interface_name"] as? String
        r.endpoint = j["test_endpoint"] as? String
        r.downloadBytes = number(j, ["dl_bytes_transferred"]).map { UInt64(max(0, $0)) }
        r.uploadBytes = number(j, ["ul_bytes_transferred"]).map { UInt64(max(0, $0)) }
        // "other": {"interface-type": {"wifi": 279}}: counts per type over the test's flows; the most common wins.
        if let other = j["other"] as? [String: Any], let types = other["interface-type"] as? [String: Any] {
            r.interfaceType = types.max { (number($0.value) ?? 0) < (number($1.value) ?? 0) }?.key
        }
        let measured = r.downloadMbps != nil || r.uploadMbps != nil || r.responsivenessRPM != nil
        if !measured {
            if let code = j["error_code"] {
                let domain = j["error_domain"] as? String
                throw SpeedTestError.reported([domain, "code \(code)"].compactMap { $0 }.joined(separator: " "))
            }
            throw SpeedTestError.noMeasurements
        }
        return r
    }

    /// The first key present with a usable number. Values may also be wrapped as {"value": n} (seen in some betas).
    static func number(_ j: [String: Any], _ keys: [String]) -> Double? {
        for k in keys { if let v = j[k], let n = number(v) { return n } }
        return nil
    }

    static func number(_ v: Any) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        if let d = v as? [String: Any], let inner = d["value"] { return number(inner) }
        return nil
    }
}
