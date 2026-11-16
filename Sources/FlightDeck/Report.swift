// The PDF "Flight Report" and the CSV/PDF export actions. Used from the Recorder menu (via the Engine extension below)
// and by the CLI's `--report`. The report is a SwiftUI view rendered to a single PDF page with ImageRenderer.
import SwiftUI
import UniformTypeIdentifiers
import FlightDeckCore

/// One-page "flight report" for a trace: what the Mac did, the peaks, what went wrong and who was responsible.
/// Always uses the light palette on white, whatever the app theme, because it's meant to be printed or shared.
struct FlightReportView: View {
    let trace: Trace
    let stats: TraceStats
    let p = Palette.of(.light)

    /// Reduces a metric to at most ~300 points by averaging consecutive frames (enough for a 540 pt wide graph).
    /// Frames where the metric is unavailable are left out of the average; a chunk with no measured frames becomes nil
    /// (a gap). Chunks are by frame index, not by time.
    func downsample(_ f: (Snapshot) -> Double?) -> [Double?] {
        let step = max(trace.frames.count / 300, 1)
        return stride(from: 0, to: trace.frames.count, by: step).map { i in
            let chunk = trace.frames[i..<min(i + step, trace.frames.count)].compactMap(f)
            return chunk.isEmpty ? nil : chunk.reduce(0, +) / Double(chunk.count)
        }
    }

    /// One stats table row: average, 95th percentile and peak, or "—" for a metric the trace never measured.
    func row(_ k: String, _ s: TraceStats.Stat?, _ fmt: (Double) -> String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(s.map { fmt($0.avg) } ?? "—"); Text(s.map { fmt($0.p95) } ?? "—"); Text(s.map { fmt($0.peak) } ?? "—")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Flight Report").font(.system(size: 26, weight: .bold))
                Spacer()
                Text("FlightDeck").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            }
            // Note: the OS version shown is that of the Mac generating the report, not necessarily the one recorded.
            Text("\(trace.host) · \(trace.model) · \(ProcessInfo.processInfo.operatingSystemVersionString)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Text("\(stats.start.formatted(date: .abbreviated, time: .standard)) – \(stats.end.formatted(date: .omitted, time: .standard)) · \(shortDuration(stats.end.timeIntervalSince(stats.start))) · \(stats.frames) samples")
                .font(.system(size: 11, design: .monospaced))
            Divider()
            Text("FINDINGS").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            if stats.findings.isEmpty { Text("Nothing notable: no sustained problems in this period.").font(.system(size: 12)) }
            ForEach(stats.findings.prefix(12)) { i in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(p.color(i.severity)).frame(width: 8, height: 8)
                    Text(i.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 11, design: .monospaced)).frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.title).font(.system(size: 12, weight: .medium))
                        Text(shortDuration(i.duration) + (i.detail.map { " · " + $0 } ?? "")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow { Text(""); Text("AVERAGE").bold(); Text("95TH PCT").bold(); Text("PEAK").bold() }.foregroundStyle(.secondary)
                row("CPU", stats.cpu) { String(format: "%.0f%%", $0) }
                row("Memory used", stats.memoryUsedFraction) { String(format: "%.0f%%", $0 * 100) }
                row("Memory pressure", stats.pressure) { String(format: "%.0f%%", $0) }
                row("Swap", stats.swap) { Fmt.bytes($0) }
                row("Disk I/O", stats.diskBps) { Fmt.rate($0) }
                row("Network", stats.netBps) { Fmt.rate($0) }
                row("System power", stats.watts) { String(format: "%.1f W", $0) }
                row("Hottest sensor", stats.hottest) { String(format: "%.0f °C", $0) }
                row("GPU", stats.gpu) { String(format: "%.0f%%", $0) }
            }.font(.system(size: 11, design: .monospaced))
            Text("Worst thermal pressure: \(["Nominal", "Fair", "Serious", "Critical"][min(stats.worstThermalState, 3)])")
                .font(.system(size: 11, design: .monospaced))
            Divider()
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TOP CPU (AVERAGE)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                    ForEach(Array(stats.topCPU.enumerated()), id: \.offset) { _, a in
                        HStack { Text(a.name).lineLimit(1); Spacer(); Text(String(format: "%.1f%%", a.avg)) }.font(.system(size: 11, design: .monospaced))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("TOP MEMORY (PEAK)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                    ForEach(Array(stats.topMemory.enumerated()), id: \.offset) { _, a in
                        HStack { Text(a.name).lineLimit(1); Spacer(); Text(Fmt.bytes(a.peak)) }.font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            Divider()
            ForEach([("CPU %", downsample { $0.cpu.total.value }, 100.0),
                     ("Memory pressure %", downsample { $0.memory.pressure.value }, 100.0),
                     ("Hottest sensor °C", downsample { $0.power.hottest.value }, 110.0)], id: \.0) { title, values, maxV in
                Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                HistoryGraph(traces: [GraphTrace(name: title, values: values, color: p.accent)], maxValue: maxV).frame(height: 70)
            }
            Text("Disk and network throughput").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            HistoryGraph(traces: [GraphTrace(name: "disk", values: downsample { s in s.disk.readBps.value.flatMap { r in s.disk.writeBps.value.map { r + $0 } } }, color: p.accent),
                                  GraphTrace(name: "net", values: downsample { s in s.network.inBps.value.flatMap { i in s.network.outBps.value.map { i + $0 } } }, color: p.accent2, fill: false)],
                         minHeadroom: 1_048_576, format: Fmt.rate).frame(height: 70)
            Text("Gaps in graphs are periods without samples. Values that weren't measured are shown as —. Per-app figures cover the processes recorded in each sample (the busiest ~30).")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(width: 612)
        .background(Color.white)
        .environment(\.palette, p)
        .environment(\.colorScheme, .light)
    }

    /// Renders the report as a single US-Letter-width (612 pt) PDF page as tall as its content. Returns nil if
    /// rendering produced nothing. Main actor because ImageRenderer is.
    @MainActor static func pdf(_ t: Trace) -> Data? {
        let r = ImageRenderer(content: FlightReportView(trace: t, stats: TraceStats.compute(t)))
        r.proposedSize = ProposedViewSize(width: 612, height: nil)
        let data = NSMutableData()
        r.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage(); ctx.closePDF()
        }
        return data.length > 0 ? data as Data : nil
    }
}

extension Engine {
    /// What exports cover: the replayed trace, or the last hour of the black box when live.
    /// Sets `lastError` and returns nil when the black box has nothing yet. Reads the black box directly (not via
    /// `blackBoxQueue` as Engine's other black box reads do).
    func exportTrace() -> Trace? {
        if mode == .replay, let trace { return trace }
        let t = blackBox.trace(.fine, from: Date().addingTimeInterval(-3600))
        if t == nil { lastError = "Nothing to export yet: open a recording, or let the black box collect some data." }
        return t
    }

    /// Renders the report first, then asks where to save it and opens the saved PDF.
    func exportReport() {
        guard let t = exportTrace(), let pdf = FlightReportView.pdf(t) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Flight Report \(t.frames.first?.time.formatted(date: .numeric, time: .shortened).replacingOccurrences(of: "/", with: "-") ?? "").pdf"
        if panel.runModal() == .OK, let u = panel.url {
            do { try pdf.write(to: u); NSWorkspace.shared.open(u) } catch { lastError = error.localizedDescription }
        }
    }

    /// System metrics (one row per sample) or per-process metrics (one row per process per sample), as CSV.
    func exportCSV(processes: Bool) {
        guard let t = exportTrace() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = processes ? "FlightDeck processes.csv" : "FlightDeck system.csv"
        if panel.runModal() == .OK, let u = panel.url {
            do { try (processes ? TraceExport.processCSV(t) : TraceExport.systemCSV(t)).write(to: u, atomically: true, encoding: .utf8) }
            catch { lastError = error.localizedDescription }
        }
    }
}
