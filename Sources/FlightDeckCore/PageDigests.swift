import Foundation
// Glanceable digests of the 1.5 pages (Destinations, Camera & Mic here; Restarts, boot time and battery health in
// PageDigestsSystem.swift) for the cockpit instruments and Ambient mode. Pure: each is built from a report the page's
// model already keeps, so drawing an instrument never reads the disk, the log or the registry. The app turns a digest
// into an InstrumentReading (Views/CockpitFeedReadings.swift).

/// Short duration and age labels shared by the digests.
public enum DigestFormat {
    /// "38 s", "2 min 5 s" (the Restarts page's boot-span style).
    public static func span(_ s: TimeInterval) -> String {
        let s = max(s, 0)
        return s < 90 ? "\(Int(s.rounded())) s" : "\(Int(s) / 60) min \(Int(s) % 60) s"
    }

    /// "now", "12 min ago", "3 h ago", "2 d ago".
    public static func ago(_ d: Date, now: Date) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86_400)) d ago"
    }

    /// "3d 4h 12m", "4h 12m" or "12m" (the Clock instrument's uptime style).
    public static func uptime(_ s: TimeInterval) -> String {
        let t = Int(max(s, 0)) / 60, d = t / 1440, h = (t % 1440) / 60, m = t % 60
        return d > 0 ? "\(d)d \(h)h \(m)m" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

/// Destinations at a glance: how many app → destination pairs are new in the last 24 hours, the newest of them, and
/// any destination with unusually heavy traffic today (`DestinationSummary.unusual`).
public struct DestinationsDigest: Sendable, Equatable {
    public struct Pair: Sendable, Equatable {
        public var app: String
        public var destination: String
        public var first: Date
        public var bytesToday: UInt64
        public var label: String { app + " → " + destination }
    }
    /// New pairs (first contacted within the last 24 h by an app already known for a day).
    public var newCount = 0
    public var newest: Pair?
    public var unusualCount = 0
    /// The unusual pair with the most traffic today.
    public var topUnusual: Pair?
    /// Distinct pairs contacted today.
    public var todayCount = 0
    /// Pairs first contacted on each of the last `days` days (oldest first), within the 30 days the page keeps.
    public var firstContactsPerDay: [Int] = []

    public init() {}

    public static func build(apps: [AppDestinations], now: Date, days: Int = 14, calendar: Calendar = .current) -> DestinationsDigest {
        var d = DestinationsDigest()
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        var perDay = Array(repeating: 0, count: max(days, 0))
        for app in apps {
            for s in app.destinations where !s.isOther {
                let pair = Pair(app: app.name, destination: s.id, first: s.first, bytesToday: s.today)
                if s.today > 0 || s.last >= today { d.todayCount += 1 }
                if s.isNew {
                    d.newCount += 1
                    if d.newest.map({ s.first > $0.first }) ?? true { d.newest = pair }
                }
                if s.unusual {
                    d.unusualCount += 1
                    if d.topUnusual.map({ s.today > $0.bytesToday }) ?? true { d.topUnusual = pair }
                }
                if s.first >= start, s.first <= now {
                    let i = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: s.first)).day ?? -1
                    if perDay.indices.contains(i) { perDay[i] += 1 }
                }
            }
        }
        d.firstContactsPerDay = perDay
        return d
    }
}

/// Camera & Mic at a glance: what is using each sensor now, or the most recent use, and how many minutes of each hour
/// of the last day each was in use.
public struct CameraMicDigest: Sendable, Equatable {
    public struct Use: Sendable, Equatable {
        public var kind: SensorKind
        public var app: String
        /// When the use ended; nil while it's ongoing.
        public var end: Date?
    }
    /// One entry per sensor in use now (camera first). A sensor running with no attributed session is "unknown app".
    public var inUse: [Use] = []
    /// The most recently ended session, when nothing is in use (or as context when something is).
    public var last: Use?
    /// Minutes in use per hour over the last `hours` hours, oldest first.
    public var cameraMinutes: [Double] = []
    public var micMinutes: [Double] = []

    public init() {}
    public var anyInUse: Bool { !inUse.isEmpty }

    public static func build(live: CameraMicLive, sessions: [SensorSession], now: Date, hours: Int = 24) -> CameraMicDigest {
        var d = CameraMicDigest()
        for k in [SensorKind.camera, .microphone] {
            let open = live.open.filter { $0.kind == k }
            if let s = open.max(by: { $0.start < $1.start }) {
                let apps = Array(Set(open.map(\.appLabel))).sorted()
                d.inUse.append(Use(kind: k, app: apps.count > 1 ? apps.joined(separator: ", ") : s.appLabel, end: nil))
            } else if !(live.running[k] ?? []).isEmpty {
                d.inUse.append(Use(kind: k, app: "unknown app", end: nil))
            }
        }
        if let s = sessions.filter({ $0.end != nil && $0.end! <= now }).max(by: { $0.end! < $1.end! }) {
            d.last = Use(kind: s.kind, app: s.appLabel, end: s.end)
        }
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        var cam = Array(repeating: 0.0, count: max(hours, 0)), mic = cam
        for s in sessions + live.open.filter({ o in !sessions.contains { $0.id == o.id } }) {
            let a = max(s.start, start), b = min(s.end ?? now, now)
            guard b > a else { continue }
            var t = a
            while t < b {
                let i = Int(t.timeIntervalSince(start) / 3600)
                let hourEnd = start.addingTimeInterval(Double(i + 1) * 3600)
                let piece = min(b, hourEnd).timeIntervalSince(t) / 60
                if cam.indices.contains(i) {
                    if s.kind == .camera { cam[i] = min(cam[i] + piece, 60) } else { mic[i] = min(mic[i] + piece, 60) }
                }
                t = hourEnd
            }
        }
        d.cameraMinutes = cam; d.micMinutes = mic
        return d
    }
}
