import SwiftUI
import UniformTypeIdentifiers
import FlightdeckCore

/// Two recordings side by side (e.g. before / after an update): statistics with deltas, overlaid graphs
/// aligned by elapsed time, and how each app's CPU and memory changed.
@MainActor
final class CompareModel: ObservableObject {
    struct Side { var url: URL; var trace: Trace; var stats: TraceStats }
    @Published var a: Side?
    @Published var b: Side?
    @Published var error: String?

    func pick(_ which: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ([Trace.fileExtension] + Trace.legacyFileExtensions).compactMap { UTType(filenameExtension: $0) }
        panel.message = which == 0 ? "Choose the first (baseline) recording" : "Choose the recording to compare"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url, into: which)
    }

    func load(_ url: URL, into which: Int) {
        do {
            let t = try Trace.read(from: url)
            let side = Side(url: url, trace: t, stats: TraceStats.compute(t))
            if which == 0 { a = side } else { b = side }
        } catch { self.error = "Could not open \(url.lastPathComponent): \(error.localizedDescription)" }
    }
}

struct CompareView: View {
    @Environment(\.palette) var p
    @StateObject private var model = CompareModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                sideButton(0, model.a)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(p.dim)
                sideButton(1, model.b)
                Spacer()
            }
            .padding(14).background(p.panel).overlay(alignment: .bottom) { Divider() }
            if let a = model.a, let b = model.b {
                ScrollView { content(a, b).padding(14) }
            } else {
                Text("Choose two recordings (.flightlog) to compare, for example before and after an app or macOS update. Saved black-box segments work too.")
                    .foregroundStyle(p.dim).frame(maxWidth: 520).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(p.background)
        .frame(minWidth: 820, minHeight: 600)
        .alert("Compare", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") {} } message: { Text(model.error ?? "") }
        .onAppear {   // automation hook: -compareA a.flightlog -compareB b.flightlog
            if let x = UserDefaults.standard.string(forKey: "compareA") { model.load(URL(fileURLWithPath: x), into: 0) }
            if let x = UserDefaults.standard.string(forKey: "compareB") { model.load(URL(fileURLWithPath: x), into: 1) }
        }
    }

    func sideButton(_ i: Int, _ s: CompareModel.Side?) -> some View {
        Button { model.pick(i) } label: {
            HStack {
                Circle().fill(i == 0 ? p.accent : p.accent2).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s?.url.lastPathComponent ?? (i == 0 ? "Choose baseline (A)…" : "Choose comparison (B)…")).lineLimit(1)
                    if let s { Text("\(s.trace.host) · \(s.stats.start.formatted(date: .abbreviated, time: .shortened)) · \(shortDuration(s.stats.end.timeIntervalSince(s.stats.start)))").font(.caption).foregroundStyle(p.dim) }
                }
            }.frame(width: 300, alignment: .leading)
        }
    }

    /// Resample a trace onto `n` points by elapsed time, so recordings of different length/interval overlay.
    /// Each point takes the nearest sample within 1.5 sampling intervals; farther than that is a real gap.
    func aligned(_ t: Trace, n: Int, span: TimeInterval, _ f: (Snapshot) -> Double?) -> [Double?] {
        guard let t0 = t.frames.first?.time, n > 1 else { return [] }
        let times = t.frames.map { $0.time.timeIntervalSince(t0) }
        let tol = max(t.interval, span / Double(n)) * 1.5
        var j = 0
        return (0..<n).map { i in
            let tc = span * Double(i) / Double(n - 1)
            while j + 1 < times.count && abs(times[j + 1] - tc) <= abs(times[j] - tc) { j += 1 }
            return abs(times[j] - tc) <= tol ? f(t.frames[j]) : nil
        }
    }

    @ViewBuilder func content(_ a: CompareModel.Side, _ b: CompareModel.Side) -> some View {
        let span = max(a.stats.end.timeIntervalSince(a.stats.start), b.stats.end.timeIntervalSince(b.stats.start))
        VStack(spacing: 12) {
            Panel(title: "Statistics", trailing: "A → B (average · 95th percentile)") {
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 5) {
                    GridRow { Text(""); Text("A avg"); Text("B avg"); Text("change"); Text("A p95"); Text("B p95") }.foregroundStyle(p.dim)
                    statRow("CPU", a.stats.cpu, b.stats.cpu, lowerIsBetter: true) { String(format: "%.1f%%", $0) }
                    statRow("Memory pressure", a.stats.pressure, b.stats.pressure, lowerIsBetter: true) { String(format: "%.0f%%", $0) }
                    statRow("Memory used", a.stats.memoryUsedFraction, b.stats.memoryUsedFraction, lowerIsBetter: true) { String(format: "%.0f%%", $0 * 100) }
                    statRow("Swap", a.stats.swap, b.stats.swap, lowerIsBetter: true) { Fmt.bytes($0) }
                    statRow("Disk I/O", a.stats.diskBps, b.stats.diskBps, lowerIsBetter: true) { Fmt.rate($0) }
                    statRow("Network", a.stats.netBps, b.stats.netBps, lowerIsBetter: nil) { Fmt.rate($0) }
                    statRow("System power", a.stats.watts, b.stats.watts, lowerIsBetter: true) { String(format: "%.1f W", $0) }
                    statRow("Hottest sensor", a.stats.hottest, b.stats.hottest, lowerIsBetter: true) { String(format: "%.0f °C", $0) }
                    statRow("GPU", a.stats.gpu, b.stats.gpu, lowerIsBetter: nil) { String(format: "%.0f%%", $0) }
                }.font(.system(size: 12, design: .monospaced))
                Text("Findings: A \(a.stats.findings.count) · B \(b.stats.findings.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                overlay("CPU %", a, b, span, max: 100) { $0.cpu.total.value }
                overlay("Memory pressure %", a, b, span, max: 100) { $0.memory.pressure.value }
                overlay("System power W", a, b, span, max: nil) { $0.power.systemWatts.value }
                overlay("Hottest sensor °C", a, b, span, max: 110) { $0.power.hottest.value }
            }
            Panel(title: "Apps: what changed", trailing: "average CPU over each recording") {
                let ac = Dictionary(a.stats.topCPU.map { ($0.name, $0.avg) }, uniquingKeysWith: max)
                let bc = Dictionary(b.stats.topCPU.map { ($0.name, $0.avg) }, uniquingKeysWith: max)
                let names = Set(ac.keys).union(bc.keys).sorted { abs((bc[$0] ?? 0) - (ac[$0] ?? 0)) > abs((bc[$1] ?? 0) - (ac[$1] ?? 0)) }
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 4) {
                    GridRow { Text("App"); Text("A"); Text("B"); Text("change") }.foregroundStyle(p.dim)
                    ForEach(names.prefix(14), id: \.self) { n in
                        GridRow {
                            Text(n).lineLimit(1)
                            Text(ac[n].map { String(format: "%.1f%%", $0) } ?? "—")
                            Text(bc[n].map { String(format: "%.1f%%", $0) } ?? "—")
                            let d = (bc[n] ?? 0) - (ac[n] ?? 0)
                            Text(String(format: "%+.1f", d)).foregroundStyle(abs(d) < 1 ? p.dim : d > 0 ? p.warn : p.accent)
                        }
                    }
                }.font(.system(size: 12, design: .monospaced))
                Text("Only apps among each recording's top 10 by CPU are listed; “—” means not in that recording's top 10.").font(.caption).foregroundStyle(p.dim)
            }
        }
    }

    func statRow(_ k: String, _ a: TraceStats.Stat?, _ b: TraceStats.Stat?, lowerIsBetter: Bool?, _ f: (Double) -> String) -> some View {
        GridRow {
            Text(k).foregroundStyle(p.dim)
            Text(a.map { f($0.avg) } ?? "—"); Text(b.map { f($0.avg) } ?? "—")
            if let a, let b, a.avg != 0 {
                let pct = (b.avg - a.avg) / abs(a.avg) * 100
                let worse = lowerIsBetter.map { $0 ? pct > 5 : pct < -5 } ?? false
                let better = lowerIsBetter.map { $0 ? pct < -5 : pct > 5 } ?? false
                Text(String(format: "%+.0f%%", pct)).foregroundStyle(worse ? p.warn : better ? p.accent : p.dim)
            } else { Text("—").foregroundStyle(p.dim) }
            Text(a.map { f($0.p95) } ?? "—"); Text(b.map { f($0.p95) } ?? "—")
        }
    }

    func overlay(_ title: String, _ a: CompareModel.Side, _ b: CompareModel.Side, _ span: TimeInterval, max: Double?, _ f: @escaping (Snapshot) -> Double?) -> some View {
        Panel(title: title, trailing: "0 – \(shortDuration(span))") {
            HistoryGraph(traces: [GraphTrace(name: "A", values: aligned(a.trace, n: 200, span: span, f), color: p.accent),
                                  GraphTrace(name: "B", values: aligned(b.trace, n: 200, span: span, f), color: p.accent2, fill: false)],
                         maxValue: max, minHeadroom: 1).frame(height: 110)
        }
    }
}
