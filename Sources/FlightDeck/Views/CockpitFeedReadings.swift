import SwiftUI
import FlightDeckCore
// The page-digest instruments as InstrumentReadings, so they draw exactly like the other gauges: a SummaryCard in the
// cockpit and a big AmbientGauge in Ambient mode. Digests are cached per source revision (or per minute where they
// depend on the clock), so a redraw per sample costs a few comparisons. Values that aren't known are "—" with the
// reason in the detail line, never 0.

extension CockpitFeeds {
    /// The reading for a page-digest kind, or nil for any other kind.
    func reading(_ kind: InstrumentKind, _ p: Palette, now: Date) -> InstrumentReading? {
        switch kind {
        case .destinations: destinationsReading(p, now: now)
        case .restarts: restartsReading(p, now: now)
        case .bootTime: bootTimeReading(p, now: now)
        case .batteryHealth: batteryReading(p)
        case .cameraMic: cameraMicReading(p, now: now)
        default: nil
        }
    }

    func destinationsReading(_ p: Palette, now: Date) -> InstrumentReading {
        let m = destinations
        let title = "Destinations"
        guard let built = m.built else {
            return InstrumentReading(title: title, value: nil, fraction: nil, showMeter: false, detail: "building the report…", traces: [])
        }
        if m.daysRecorded == 0 && m.apps.isEmpty {
            return InstrumentReading(title: title, value: nil, fraction: nil, showMeter: false, detail: "no connections recorded yet", traces: [])
        }
        let d = digests.destinations(built: built, apps: m.apps, now: now)
        var parts: [String] = []
        var color: Color?
        if let u = d.topUnusual {
            parts.append("unusual traffic: " + u.label + " (" + Fmt.bytes(u.bytesToday) + " today)")
            color = p.warn
        }
        if let n = d.newest { parts.append("newest: " + n.label) } else { parts.append("none new in 24 h") }
        parts.append("\(d.todayCount) today")
        let trace = GraphTrace(name: "new", values: d.firstContactsPerDay.map(Double.init), color: p.accent)
        return InstrumentReading(title: title, value: "\(d.newCount) new", fraction: nil, showMeter: false,
                                 detail: parts.joined(separator: " · "), traces: [trace], minHeadroom: 4, detailColor: color)
    }

    func restartsReading(_ p: Palette, now: Date) -> InstrumentReading {
        // The report's current boot when there is one (so demo data never shows this Mac's uptime), else kern.boottime.
        let boot = restarts.flatMap { $0.current?.boot ?? $0.events.map(\.boot).max() } ?? ClockInstrument.bootTime
        let up = boot.map { DigestFormat.uptime(now.timeIntervalSince($0)) }
        guard let r = restarts else {
            return InstrumentReading(title: "Restarts", value: up, fraction: nil, showMeter: false,
                                     detail: "uptime · reading the boot history…", traces: [])
        }
        let d = RestartsDigest.build(r, now: now)
        var parts = [d.lastEndLabel.map { "last ended " + $0 } ?? "no boots recorded"]
        if let days = d.daysSinceUnexpected(now: now) {
            parts.append(days == 0 ? "unexpected today" : "\(days) d since unexpected")
        } else if let since = d.recordsSince {
            parts.append("none unexpected since " + since.formatted(.dateTime.day().month(.abbreviated)))
        }
        let color: Color? = d.lastEnd == .panic ? p.crit : d.lastEnd == .unexpected ? p.warn : nil
        let trace = GraphTrace(name: "sessions", values: d.sessionDays, color: p.accent)
        return InstrumentReading(title: "Restarts", value: up, fraction: nil, showMeter: false,
                                 detail: parts.joined(separator: " · "), traces: [trace], minHeadroom: 1, detailColor: color)
    }

    func bootTimeReading(_ p: Palette, now: Date) -> InstrumentReading {
        let title = "Boot Time"
        guard let r = restarts else {
            return InstrumentReading(title: title, value: nil, fraction: nil, showMeter: false, detail: "reading the boot history…", traces: [])
        }
        let d = BootTimeDigest.build(r, now: now)
        let detail: String
        if d.current == nil {
            detail = r.current == nil ? "this boot's timing couldn't be read" : "no desktop recorded for this boot yet"
        } else {
            detail = (d.comparison ?? "typical needs \(BootTimeDigest.minEarlier) saved boots (\(d.earlierCount) so far)") + " · boot → desktop"
        }
        var traces = [GraphTrace(name: "boot", values: d.recent, color: p.accent)]
        if let t = d.typical, d.recent.count > 1 {
            traces.append(GraphTrace(name: "typical", values: d.recent.map { _ in t }, color: p.accent2, fill: false))
        }
        return InstrumentReading(title: title, value: d.current.map(DigestFormat.span), fraction: nil, showMeter: false,
                                 detail: detail, traces: traces, minHeadroom: 30, detailColor: d.isSlow ? p.warn : nil)
    }

    func batteryReading(_ p: Palette) -> InstrumentReading {
        let title = "Battery Health"
        guard let r = battery, let built = batteryBuilt else {
            return InstrumentReading(title: title, value: nil, fraction: nil, detail: "reading the battery history…", traces: [])
        }
        let d = digests.battery(built: built, report: r)
        guard d.hasBattery else {
            return InstrumentReading(title: title, value: nil, fraction: nil, showMeter: false, detail: "this Mac has no battery", traces: [])
        }
        let outlook: String
        if case .reaches = d.outlook { outlook = "80% ≈ " + d.outlookLabel } else { outlook = "80%: " + d.outlookLabel }
        let cycles = d.cycles.map { c in d.designCycles.map { "\(c)/\($0) cycles" } ?? "\(c) cycles" }
        let floor = d.graphFloor
        let low = (d.health ?? 100) < BatteryForecast.threshold
        return InstrumentReading(title: title, value: d.health.map { String(format: "%.0f%%", $0) }, fraction: d.health.map { $0 / 100 },
                                 detail: [cycles, outlook].compactMap { $0 }.joined(separator: " · "),
                                 traces: [GraphTrace(name: "health", values: d.history.map { $0 - floor }, color: p.accent)],
                                 maxValue: 100 - floor, meterColor: low ? p.warn : p.accent)
    }

    func cameraMicReading(_ p: Palette, now: Date) -> InstrumentReading {
        let m = cameraMic
        let d = digests.cameraMic(live: m.live, sessions: m.sessions, now: now)
        let kinds = Set(d.inUse.map(\.kind))
        let value = kinds.count == 2 ? "cam + mic" : kinds.contains(.camera) ? "camera" : kinds.contains(.microphone) ? "mic" : "off"
        let detail: String
        if d.anyInUse {
            // One entry per app, so "zoom.us (camera + mic)" fits a small card.
            let apps = d.inUse.reduce(into: [String: [String]]()) { $0[$1.app, default: []].append($1.kind == .camera ? "camera" : "mic") }
            detail = apps.keys.sorted().map { "\($0) (" + (apps[$0] ?? []).joined(separator: " + ") + ")" }.joined(separator: " · ")
        } else if let l = d.last, let end = l.end {
            detail = "last: \(l.app) · \(l.kind.noun) · " + DigestFormat.ago(end, now: now)
        } else {
            detail = "no use recorded"
        }
        let traces = [GraphTrace(name: "camera", values: d.cameraMinutes, color: p.accent),
                      GraphTrace(name: "mic", values: d.micMinutes, color: p.accent2, fill: false)]
        return InstrumentReading(title: "Camera & Mic", value: value, fraction: nil, showMeter: false, detail: detail,
                                 traces: traces, maxValue: 60, detailColor: d.anyInUse ? p.warn : nil)
    }
}

/// Digest caches, so redrawing once per sample doesn't rebuild a month of destinations or sessions.
@MainActor
final class FeedDigestCache {
    private var dest: (built: Date, day: Date, d: DestinationsDigest)?
    private var batt: (built: Date, d: BatteryHealthDigest)?
    private var cam: (key: [Int], d: CameraMicDigest)?

    func destinations(built: Date, apps: [AppDestinations], now: Date) -> DestinationsDigest {
        let day = Calendar.current.startOfDay(for: now)
        if let c = dest, c.built == built, c.day == day { return c.d }
        let d = DestinationsDigest.build(apps: apps, now: now)
        dest = (built, day, d)
        return d
    }

    func battery(built: Date, report: BatteryReport) -> BatteryHealthDigest {
        if let c = batt, c.built == built { return c.d }
        let d = BatteryHealthDigest.build(report)
        batt = (built, d)
        return d
    }

    /// Keyed by the minute, the number of sessions and what's open or running now.
    func cameraMic(live: CameraMicLive, sessions: [SensorSession], now: Date) -> CameraMicDigest {
        let running = SensorKind.allCases.map { live.running[$0]?.count ?? 0 }
        let key = [Int(now.timeIntervalSince1970 / 60), sessions.count, live.open.count] + running
        if let c = cam, c.key == key { return c.d }
        let d = CameraMicDigest.build(live: live, sessions: sessions, now: now)
        cam = (key, d)
        return d
    }
}

/// Draws a page-digest reading with `content`, observing the source it comes from and keeping that source fresh
/// while on screen (CockpitFeeds.keepFresh). Draws nothing for kinds that aren't page digests.
struct FeedReading<Content: View>: View {
    @Environment(\.cockpitFeeds) private var override
    var kind: InstrumentKind
    /// Fixed time (Ambient's clock, off-screen renders); nil = now.
    var now: Date? = nil
    @ViewBuilder var content: (InstrumentReading) -> Content

    var body: some View {
        let f = override ?? .shared
        switch kind {
        case .destinations: FeedObserver(feeds: f, source: f.destinations, kind: kind, now: now, content: content)
        case .cameraMic: FeedObserver(feeds: f, source: f.cameraMic, kind: kind, now: now, content: content)
        default: FeedObserver(feeds: f, source: f, kind: kind, now: now, content: content)
        }
    }
}

private struct FeedObserver<Source: ObservableObject, Content: View>: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @ObservedObject var feeds: CockpitFeeds
    @ObservedObject var source: Source
    var kind: InstrumentKind
    var now: Date?
    var content: (InstrumentReading) -> Content

    var body: some View {
        if let r = feeds.reading(kind, p, now: now ?? Date()) {
            content(r).task(id: kind) { await feeds.keepFresh(kind, engine: e) }
        }
    }
}
