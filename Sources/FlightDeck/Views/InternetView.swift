// Internet destination: how good the connection beyond the router is, and which apps use it. The speed and
// responsiveness test (macOS's networkQuality, run only on request or on the opt-in schedule), its plain-English
// reading, the Wi-Fi link and latency probe right now, test history over 7 or 30 days, and per-app data usage from
// the daily log. A separate destination rather than a Network tab: the Network page is the local network map (and
// only does discovery while open), while this page is about the internet path and per-app traffic over days.
import SwiftUI
import FlightDeckCore

struct InternetView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @ObservedObject var model: InternetModel = .shared
    @AppStorage("internetDays") private var days = 7
    @State private var usage: DataUsageReport?
    /// Off-screen renders pass the usage report directly (`.task` doesn't run in ImageRenderer).
    var previewUsage: DataUsageReport? = nil

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                SpeedTestControlPanel(model: model)
                if let r = model.latest { LatestResultPanel(r: r) }
                HStack(alignment: .top, spacing: 12) {
                    LinkNowPanel(snapshot: model.demo ? nil : e.current, demo: model.demo)
                    SpeedHistoryPanel(results: model.results(days: days), days: $days)
                }
                DataUsagePanel(report: previewUsage ?? usage)
            }
            .padding(16)
        }
        // The daily log is copied off the main actor once a minute while the page is open; nothing is recomputed per
        // sample.
        .task {
            guard previewUsage == nil else { return }
            while !Task.isCancelled {
                let log = e.dailyLog, demo = model.demo
                usage = await Task.detached(priority: .utility) {
                    DataUsageReport.build(days: demo ? Demo.dataUsageDays() : log.history().days)
                }.value
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

/// The run button, the cost warning, progress and the schedule's state.
struct SpeedTestControlPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: InternetModel

    var body: some View {
        Panel(title: "Speed and responsiveness test", trailing: model.demo ? "demo data: no test runs" : nil) {
            HStack(alignment: .center, spacing: 14) {
                if model.running {
                    Button("Cancel") { model.cancel() }
                    // networkQuality reports nothing until it's done, so progress is elapsed time against a typical run.
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        let el = ctx.date.timeIntervalSince(model.runningSince ?? ctx.date)
                        HStack(spacing: 8) {
                            ProgressView(value: min(el / InternetModel.typicalSeconds, 0.97)).frame(width: 220)
                            Text(String(format: "Measuring… %.0f s", el)).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.text)
                        }
                    }
                } else {
                    Button { model.start() } label: { Label("Run Test", systemImage: "speedometer") }
                        .disabled(model.demo || !SpeedTestRun.isAvailable)
                }
                Text("Uses macOS's networkQuality against Apple's test servers. Takes about 15–20 s and transfers real data (hundreds of MB on a fast line), so avoid it on a metered connection.")
                    .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let err = model.lastError {
                Label("Test failed: \(err)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(p.warn)
            }
            if !SpeedTestRun.isAvailable && !model.demo {
                Text("networkQuality isn't available on this Mac.").font(.caption).foregroundStyle(p.warn)
            }
            Text(scheduleText).font(.caption).foregroundStyle(p.dim)
        }
    }

    var scheduleText: String {
        let h = model.scheduleHours
        if model.demo || h == 0 { return "Scheduled tests are off (Settings › Network)." }
        let base = "Scheduled every \(h) hour\(h == 1 ? "" : "s") while FlightDeck runs; skipped on battery below 20%, hotspots and metered connections."
        if let note = model.scheduleNote { return base + " " + note + "." }
        if case .notDue(let d) = model.decision() { return base + " Next \(d.formatted(date: .omitted, time: .shortened))." }
        return base
    }
}

/// The latest result as big readouts, with the verdict.
struct LatestResultPanel: View {
    @Environment(\.palette) var p
    var r: SpeedTestResult

    func num(_ v: Double?, _ f: String = "%.0f") -> String? { v.map { String(format: f, $0) } }

    var body: some View {
        let level = r.responsivenessRPM.map(SpeedTestVerdict.responsiveness)
        let levelColor = level == .low ? p.crit : level == .medium ? p.warn : p.accent
        Panel(title: "Latest result", trailing: r.time.formatted(date: .abbreviated, time: .shortened) + (r.scheduled ? " · scheduled" : "")) {
            HStack(alignment: .top, spacing: 28) {
                Readout(label: "Download", value: num(r.downloadMbps), unit: "Mbps", size: 34)
                Readout(label: "Upload", value: num(r.uploadMbps), unit: "Mbps", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Readout(label: "Responsiveness", value: num(r.responsivenessRPM), unit: "RPM", color: levelColor, size: 34)
                    if let level { Text(level.rawValue.uppercased()).font(.meterLabel).foregroundStyle(levelColor) }
                }
                Readout(label: "Idle latency", value: num(r.baseRTTms), unit: "ms", size: 34)
                Readout(label: "Loaded latency", value: num(r.loadedLatencyMs), unit: "ms", size: 34)
                    .help("Derived from responsiveness: 60 000 ÷ RPM")
                Spacer(minLength: 0)
            }
            Text(SpeedTestVerdict.headline(r)).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(p.text)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(SpeedTestVerdict.lines(r)) { l in
                // Status is icon + words, never colour alone.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: l.kind == .good ? "checkmark.circle" : l.kind == .caution ? "exclamationmark.triangle" : "info.circle")
                        .foregroundStyle(l.kind == .caution ? p.warn : p.dim)
                    Text(l.text).foregroundStyle(p.text).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11, design: .monospaced))
            }
            Text(details).font(.caption).foregroundStyle(p.dim)
        }
    }

    var details: String {
        var parts: [String] = []
        if let i = r.interface { parts.append("via \(i)" + (r.interfaceType.map { " (\($0))" } ?? "")) }
        if let ep = r.endpoint { parts.append("server \(ep)") }
        let moved = (r.downloadBytes ?? 0) + (r.uploadBytes ?? 0)
        if moved > 0 { parts.append("transferred \(Fmt.storage(moved))") }
        return parts.isEmpty ? "No connection details reported." : parts.joined(separator: " · ")
    }
}
