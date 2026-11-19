import Foundation
// The Wi-Fi link over time for the Wi-Fi page: points taken from the readings already in each snapshot (the sampler
// re-reads CoreWLAN every 5 s; nothing extra is sampled), and the events worth marking on the graph: roaming to
// another access point, band and channel changes, drops and reconnects.

/// One reading of the associated link.
public struct WiFiLinkPoint: Codable, Sendable, Hashable {
    public var time: Date
    public var rssi: Int
    public var noise: Int
    public var txRate: Double
    public var channel: Int?
    public var band: WiFiBand?
    public var widthMHz: Int?
    /// nil without Location permission.
    public var bssid: String?
    public var snr: Int { rssi - noise }

    public init(time: Date, rssi: Int, noise: Int, txRate: Double, channel: Int?, band: WiFiBand?, widthMHz: Int?, bssid: String?) {
        self.time = time; self.rssi = rssi; self.noise = noise; self.txRate = txRate; self.channel = channel; self.band = band
        self.widthMHz = widthMHz; self.bssid = bssid
    }

    public init(_ w: WiFiInfo, time: Date) {
        self.init(time: time, rssi: w.rssi, noise: w.noise, txRate: w.txRate, channel: w.channel, band: WiFiBand(label: w.band),
                  widthMHz: WiFiChannels.widthMHz(w.width), bssid: w.bssid)
    }
}

/// Something that changed between two readings.
public struct WiFiLinkEvent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// The BSSID changed: the Mac moved to another access point (or another radio of the same one).
        case roam
        /// Same BSSID, different band: shouldn't happen (a BSSID is one radio) but is reported if seen.
        case bandChange
        /// BSSID unknown (no Location permission) and the band or channel changed: probably a roam, possibly the
        /// access point changing channel. Can't be told apart without the BSSID.
        case channelChange
        case disconnected, reconnected
    }
    public var id: String { "\(time.timeIntervalSince1970)-\(kind.rawValue)" }
    public var time: Date
    public var kind: Kind
    public var text: String
}

/// A bounded in-memory history of link readings, fed while the Wi-Fi page is visible. Not persisted.
public struct WiFiLinkHistory: Sendable {
    public private(set) var points: [WiFiLinkPoint] = []
    /// Times the link was absent (not associated) after having been present, so drops show as breaks.
    public private(set) var drops: [Date] = []
    public let capacity: Int
    public init(capacity: Int = 3600) { self.capacity = capacity }

    /// Adds a reading. Readings repeat between CoreWLAN refreshes (every 5 s), so an identical reading less than 5 s
    /// after the previous one is skipped; the graph then has one point per real read.
    public mutating func add(_ p: WiFiLinkPoint) {
        if let last = points.last {
            guard p.time > last.time else { return }
            let same = last.rssi == p.rssi && last.noise == p.noise && last.txRate == p.txRate && last.bssid == p.bssid && last.channel == p.channel
            if same && p.time.timeIntervalSince(last.time) < 5 { return }
        }
        points.append(p)
        if points.count > capacity { points.removeFirst(points.count - capacity) }
    }

    /// Notes that the Mac wasn't associated at `time` (only after a reading, so start-up isn't a "drop").
    public mutating func addAbsent(at time: Date) {
        guard let last = points.last, last.time < time, drops.last.map({ $0 < last.time }) ?? true else { return }
        drops.append(time)
    }

    public mutating func replace(_ points: [WiFiLinkPoint], drops: [Date] = []) { self.points = points; self.drops = drops }

    public var events: [WiFiLinkEvent] { WiFiLinkHistory.events(points, drops: drops) }

    /// Events between consecutive readings, oldest first. A gap with a recorded drop between two readings is a
    /// disconnect and reconnect; the readings on each side are then not compared for roaming (reconnecting to another
    /// AP after a drop is a reconnect, not a roam).
    public static func events(_ points: [WiFiLinkPoint], drops: [Date] = []) -> [WiFiLinkEvent] {
        var out: [WiFiLinkEvent] = []
        for (a, b) in zip(points, points.dropFirst()) {
            if let d = drops.first(where: { $0 > a.time && $0 < b.time }) {
                out.append(WiFiLinkEvent(time: d, kind: .disconnected, text: "Wi-Fi disconnected"))
                out.append(WiFiLinkEvent(time: b.time, kind: .reconnected, text: "Reconnected" + where_(b)))
                continue
            }
            if let x = a.bssid, let y = b.bssid {
                if x != y {
                    let bandNote = a.band != b.band ? ", \(a.band?.rawValue ?? "?") → \(b.band?.rawValue ?? "?")" : ""
                    out.append(WiFiLinkEvent(time: b.time, kind: .roam, text: "Roamed to another access point (\(y))\(bandNote)" + where_(b)))
                } else if a.band != b.band {
                    out.append(WiFiLinkEvent(time: b.time, kind: .bandChange, text: "Band changed to \(b.band?.rawValue ?? "unknown")"))
                } else if a.channel != b.channel {
                    out.append(WiFiLinkEvent(time: b.time, kind: .channelChange, text: "The access point changed channel" + where_(b)))
                }
            } else if a.band != b.band || a.channel != b.channel {
                out.append(WiFiLinkEvent(time: b.time, kind: .channelChange,
                                         text: "Channel changed" + where_(b) + "; probably a roam, but the BSSID is hidden without Location permission"))
            }
        }
        return out
    }

    private static func where_(_ p: WiFiLinkPoint) -> String {
        guard let c = p.channel else { return "" }
        return " (\(p.band?.rawValue ?? "?") channel \(c))"
    }
}
