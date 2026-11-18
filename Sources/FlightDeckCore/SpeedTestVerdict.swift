import Foundation

// Plain-English reading of a speed test: what the numbers mean for everyday use, whether Wi-Fi or the router looks
// like the bottleneck (from the Wi-Fi link and latency probe captured when the test started), and bufferbloat.
// The bands are FlightDeck's rules of thumb, stated in the text so the user can judge them; they are not Apple's.

public enum SpeedTestVerdict {
    /// Responsiveness bands by RPM. 200 RPM is 300 ms per round trip once the link is busy (calls stutter, games
    /// lag); 800 RPM is 75 ms (barely noticeable).
    public enum Responsiveness: String, Sendable { case low = "Low", medium = "Medium", high = "High" }

    public static func responsiveness(_ rpm: Double) -> Responsiveness {
        rpm < 200 ? .low : rpm < 800 ? .medium : .high
    }

    public struct Line: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable { case good, caution, info }
        public var id: String { text }
        public var kind: Kind
        public var text: String
    }

    /// "412 Mbps", "8.4 Mbps", "1.2 Gbps".
    public static func mbps(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.2f Gbps", v / 1000) : v >= 100 ? String(format: "%.0f Mbps", v) : String(format: "%.1f Mbps", v)
    }

    /// One sentence summing the test up, e.g. "Download 412 Mbps; responsiveness Low: video calls may stutter under
    /// load (bufferbloat)."
    public static func headline(_ r: SpeedTestResult) -> String {
        var parts: [String] = []
        if let d = r.downloadMbps { parts.append("Download \(mbps(d))") }
        if let u = r.uploadMbps { parts.append("upload \(mbps(u))") }
        var s = parts.joined(separator: ", ")
        if let rpm = r.responsivenessRPM {
            let level = responsiveness(rpm)
            let meaning: String
            switch level {
            case .low: meaning = "video calls may stutter under load (bufferbloat)"
            case .medium: meaning = "fine for browsing and streaming, but calls may lag while something else uses the connection"
            case .high: meaning = "calls and games should stay smooth even while the connection is busy"
            }
            s += (s.isEmpty ? "Responsiveness" : "; responsiveness") + " \(level.rawValue): \(meaning)"
        } else if s.isEmpty {
            s = "No measurements"
        }
        return s + "."
    }

    /// Detail lines, most important first.
    public static func lines(_ r: SpeedTestResult) -> [Line] {
        var out: [Line] = []
        if let d = r.downloadMbps {
            switch d {
            case ..<5: out.append(Line(kind: .caution, text: "Download \(mbps(d)) is too slow for HD video; pages and updates will feel slow."))
            case ..<25: out.append(Line(kind: .info, text: "Download \(mbps(d)) is enough for one HD stream or video call at a time."))
            case ..<100: out.append(Line(kind: .good, text: "Download \(mbps(d)) handles several HD streams at once."))
            default: out.append(Line(kind: .good, text: "Download \(mbps(d)) is plenty for 4K streaming and large downloads."))
            }
        } else {
            out.append(Line(kind: .info, text: "Download speed wasn't measured in this run."))
        }
        if let u = r.uploadMbps {
            if u < 3 { out.append(Line(kind: .caution, text: "Upload \(mbps(u)) is low: your video in calls may look blurry, and backups and uploads will be slow.")) }
            else if u < 10 { out.append(Line(kind: .info, text: "Upload \(mbps(u)) is fine for a video call; large uploads take a while.")) }
            else { out.append(Line(kind: .good, text: "Upload \(mbps(u)) is comfortable for calls, screen sharing and cloud backups.")) }
        }
        if let loaded = r.loadedLatencyMs {
            let base = r.baseRTTms.map { String(format: " (%.0f ms when idle)", $0) } ?? ""
            let text = String(format: "Under load, a round trip takes about %.0f ms", loaded) + base + "."
            if let inc = r.latencyIncreaseMs, inc > 100 {
                out.append(Line(kind: .caution, text: text + String(format: " The extra %.0f ms is bufferbloat: the router or modem queues too much data. Smart queue management (SQM/fq_codel) on the router, if it has it, usually fixes this.", inc)))
            } else {
                out.append(Line(kind: loaded < 100 ? .good : .info, text: text))
            }
        }
        if let b = r.baseRTTms, b > 100 {
            out.append(Line(kind: .caution, text: String(format: "Even idle, the round trip to the test server is %.0f ms: a slow path (satellite, mobile, VPN or a distant server).", b)))
        }
        out += linkLines(r)
        return out
    }

    /// Compares the result with the Wi-Fi link and the latency probe captured when the test started.
    static func linkLines(_ r: SpeedTestResult) -> [Line] {
        var out: [Line] = []
        let c = r.context
        if let rate = c?.wifiTxRate, rate > 0, let rssi = c?.wifiRSSI {
            let signal = "signal \(rssi) dBm, link rate \(Int(rate)) Mbps"
            // Real Wi-Fi throughput tops out around half to two-thirds of the PHY rate (airtime, overhead).
            let best = [r.downloadMbps, r.uploadMbps].compactMap { $0 }.max()
            if rssi < -70 {
                out.append(Line(kind: .caution, text: "Wi-Fi is weak (\(signal)). It is probably limiting speed and adding delay: move closer to the router or add an access point."))
            } else if let best, best >= rate * 0.5 {
                out.append(Line(kind: .info, text: "Wi-Fi is likely the limit: the test reached \(Int(best / rate * 100))% of the Wi-Fi link rate (\(signal)). Real Wi-Fi rarely exceeds two-thirds of it; a wired connection or a faster band would go higher."))
            } else {
                out.append(Line(kind: .good, text: "Wi-Fi isn't the bottleneck (\(signal)); the limit is further out, at the router or your internet plan."))
            }
        } else if r.interfaceType == "wiredethernet" {
            out.append(Line(kind: .info, text: "Tested over a wired connection, so Wi-Fi isn't a factor."))
        }
        if let ms = c?.routerMs {
            if ms > 20 || (c?.routerLoss ?? 0) > 1 {
                out.append(Line(kind: .caution, text: String(format: "Your router took %.0f ms to answer pings (healthy is under about 10 ms) with %.0f%% loss: the delay starts on the local network, not at your provider.", ms, c?.routerLoss ?? 0)))
            } else if let ims = c?.internetMs {
                out.append(Line(kind: .good, text: String(format: "Router answers in %.0f ms and the internet host in %.0f ms: the local network is healthy.", ms, ims)))
            }
        }
        if let loss = c?.internetLoss, loss > 2, (c?.routerLoss ?? 0) <= 1 {
            out.append(Line(kind: .caution, text: String(format: "%.0f%% of pings to the internet were lost while the router lost none: packet loss is beyond your network, at the provider.", loss)))
        }
        if c?.routerMs == nil && c?.internetMs == nil {
            out.append(Line(kind: .info, text: "Turn on latency probing (Settings › Network) to also compare with your router's and the internet's ping times."))
        }
        return out
    }
}
