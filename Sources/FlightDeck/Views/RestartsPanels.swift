import SwiftUI
import FlightDeckCore
// Restarts & Crashes panels: shutdowns grouped by cause, kernel panic reports, app freezes, and what the records can't
// tell. Layout parts of RestartsView.

/// How the sessions ended, counted by verdict title, most frequent first.
struct CauseGroupsPanel: View {
    @Environment(\.palette) var p
    var events: [BootEvent]
    var body: some View {
        let groups = BootHistory.grouped(events)
        Panel(title: "By cause", trailing: "\(events.count) boots") {
            ForEach(groups, id: \.title) { g in
                HStack(spacing: 8) {
                    Image(systemName: g.kind.icon).foregroundStyle(g.kind.color(p)).frame(width: 14)
                    Text(g.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text("×\(g.count)").foregroundStyle(p.dim)
                    Text(g.last.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(p.dim).frame(width: 90, alignment: .trailing)
                }.font(.system(size: 11, design: .monospaced))
            }
            if groups.isEmpty { Text("No boots recorded.").foregroundStyle(p.dim) }
        }
    }
}

/// App hangs and spins from macOS's reports (the freezes users notice), plus wakes from hibernation, which feel like a
/// slow, frozen wake but are normal.
struct FreezesPanel: View {
    @Environment(\.palette) var p
    var hangs: [DiagnosticReport]
    var wakes: [PowerLogEvent]
    var body: some View {
        Panel(title: "Freezes", trailing: "last 30 days") {
            ForEach(hangs.prefix(8)) { h in
                HStack(spacing: 8) {
                    Image(systemName: "hourglass").foregroundStyle(p.warn).frame(width: 14)
                    Text(h.process).lineLimit(1).frame(width: 140, alignment: .leading)
                    Text(h.summary ?? "").foregroundStyle(p.dim).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(h.time.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(p.dim)
                }.font(.system(size: 11, design: .monospaced))
            }
            if hangs.isEmpty { Text("No app hangs reported by macOS.").font(.system(size: 11)).foregroundStyle(p.dim) }
            else {
                Text("An app that stops responding (spinning cursor) gets a hang report. If one app freezes repeatedly, update it; if the whole Mac freezes and restarts, see the panics below.")
                    .font(.system(size: 11)).foregroundStyle(p.dim).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(wakes.suffix(3), id: \.time) { w in
                Text("Woke from hibernation \(w.time.formatted(date: .abbreviated, time: .shortened)): memory was restored from disk, so the wake took longer than usual. Normal after a long sleep or low battery.")
                    .font(.system(size: 11)).foregroundStyle(p.dim).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Every kernel panic report: when, the plain-English culprit and advice, then the raw headline, task and kexts.
struct PanicsPanel: View {
    @Environment(\.palette) var p
    var panics: [PanicReport]
    var body: some View {
        Panel(title: "Kernel panics", trailing: "\(panics.count) report\(panics.count == 1 ? "" : "s") in 90 days") {
            ForEach(panics.prefix(10)) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(p.crit)
                        Text(r.time.formatted(date: .abbreviated, time: .shortened) + (r.timeIsPanic ? "" : " (report written)")).frame(width: 190, alignment: .leading)
                        Text(r.culprit.rawValue + (r.culpritName.map { ": \($0)" } ?? "")).foregroundStyle(p.crit)
                        Spacer()
                        Text(r.osVersion ?? "").foregroundStyle(p.dim)
                    }.font(.system(size: 12, design: .monospaced))
                    Text(r.explanation).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    Text("“\(r.headline)”").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).lineLimit(2)
                    Text(["task: \(r.task ?? "not named")", r.kexts.isEmpty ? nil : "drivers in backtrace: " + r.kexts.prefix(4).joined(separator: ", "),
                          (r.path as NSString).lastPathComponent].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).lineLimit(1)
                }.padding(.vertical, 2)
            }
            if panics.isEmpty {
                Text("No kernel panic reports in /Library/Logs/DiagnosticReports (or its Retired folder) from the last 90 days.")
                    .font(.system(size: 11)).foregroundStyle(p.dim)
            }
        }
    }
}

/// Where each source stops, in plain words, and the SSD's lifetime unsafe-shutdown counter.
struct LimitsPanel: View {
    @Environment(\.palette) var p
    var report: RestartsReport
    var body: some View {
        Panel(title: "What these records can and can't tell") {
            ForEach(report.limits, id: \.self) { line in
                Text("· " + line).font(.system(size: 11)).foregroundStyle(p.dim).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("· Shutdown cause codes are not documented by Apple: meanings marked “reported, not confirmed” come from repair and support reports; unknown codes are shown as undocumented.")
                .font(.system(size: 11)).foregroundStyle(p.dim).frame(maxWidth: .infinity, alignment: .leading)
            if let s = report.ssd {
                Text("· The internal SSD has counted \(s.unsafe) unsafe shutdowns in \(s.cycles) power cycles over its whole life (its own counter, including before these records; it can also count some sleeps where power was cut).")
                    .font(.system(size: 11)).foregroundStyle(p.dim).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
