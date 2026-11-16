// Console destination: errors and faults from the unified log, grouped by process and subsystem, with counts,
// sparklines, a filter, the noisiest processes, sample messages for the selected group, and an optional live tail.
// All the work (running `log`, parsing, grouping) is in ConsoleModel / FlightDeckCore; this file only lays it out.
// Nothing runs unless this view is on screen: a query starts on appear, and everything stops on disappear.
import SwiftUI
import FlightDeckCore

struct ConsoleView: View {
    @Environment(\.palette) var p
    @StateObject private var model: ConsoleModel
    @State private var filter = ""
    @State private var selected: String?
    /// UIBench passes a model that has already loaded, and skips the automatic query.
    private let autoload: Bool

    init(model: ConsoleModel? = nil) {
        _model = StateObject(wrappedValue: model ?? ConsoleModel())
        autoload = model == nil
    }

    /// Group rows drawn at most; the rest are summarised in one line (thousands of rows would make the view sluggish).
    static let maxRows = 200

    var body: some View {
        // Demo mode must never show this Mac's real log messages.
        if Demo.isEnabled {
            Panel(title: "Console") {
                Text("Not available in demo mode: the Console shows this Mac's real log messages.").foregroundStyle(p.dim)
            }.padding(16).frame(maxHeight: .infinity, alignment: .top)
        } else {
            MaybeScroll {
                VStack(alignment: .leading, spacing: 12) {
                    controls
                    if model.tailWanted { tailPanel }
                    if let s = model.summary, let r = model.range {
                        noisiest(s)
                        HStack(alignment: .top, spacing: 12) {
                            groupList(s, from: r.from, to: r.to, bucket: s.bucketWidth, slots: ConsoleModel.sparkSlots)
                                .frame(minWidth: 520)
                            detail(s)
                        }
                    }
                }.padding(16)
            }
            .onAppear { if autoload && model.summary == nil && !model.loading { model.load() } }
            .onDisappear { model.stopAll() }
        }
    }

    // MARK: Header

    private var controls: some View {
        Panel(title: "Errors and faults", trailing: "unified log") {
            HStack(spacing: 10) {
                Picker("Window", selection: $model.span) { ForEach(ConsoleModel.Span.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 260).labelsHidden()
                    .onChange(of: model.span) { model.load() }
                if model.loading {
                    Button("Cancel") { model.cancel() }
                } else {
                    Button("Reload") { model.load() }
                }
                Toggle("Live tail", isOn: Binding(get: { model.tailWanted }, set: { model.setTail($0) })).toggleStyle(.switch).controlSize(.small)
                Spacer()
                TextField("Filter process, subsystem or message", text: $filter).textFieldStyle(.roundedBorder).frame(width: 280)
            }
            if model.loading {
                ProgressView(value: model.progress) {
                    Text("Reading the log… \(Int(model.progress * 100))%" + (model.summary.map { " · \($0.total.formatted()) so far" } ?? ""))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                }
            }
            if let s = model.summary { Text(statusLine(s)).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim) }
            if let o = model.outcome, let m = outcomeText(o, model.summary) {
                Text(m).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.warn).fixedSize(horizontal: false, vertical: true)
            }
            // Redaction is a macOS privacy feature: arguments not marked public are replaced before anyone can read them.
            Text("macOS replaces message details it considers private with <private>, so some messages are incomplete; FlightDeck can't see what was removed. Errors and faults are often routine: a busy group isn't necessarily a problem.")
                .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusLine(_ s: LogSummary) -> String {
        var parts = ["\(s.total.formatted()) messages (\(s.faults.formatted()) faults) in \(s.groups.count.formatted()) groups"]
        if let a = s.earliest, let b = s.latest {
            parts.append("\(a.formatted(date: .omitted, time: .standard)) – \(b.formatted(date: .omitted, time: .standard))")
        }
        if s.total > 0 { parts.append("\(Int((Double(s.redacted) / Double(s.total) * 100).rounded()))% contain <private>") }
        if s.entries.count < s.total { parts.append("newest \(s.entries.count.formatted()) kept for samples") }
        return parts.joined(separator: " · ")
    }

    private func outcomeText(_ o: LogReader.Outcome, _ s: LogSummary?) -> String? {
        let from = s?.earliest.map { " (from \($0.formatted(date: .abbreviated, time: .shortened)))" } ?? ""
        switch o {
        case .finished: return nil
        case .cancelled: return "Cancelled: showing only what was read\(from)."
        case .capped: return "Stopped at 1,000,000 messages: showing the newest part of the window\(from)."
        case .failed(let m): return "Couldn't read the log: \(m)"
        }
    }

    // MARK: Summary panels

    private func noisiest(_ s: LogSummary) -> some View {
        Panel(title: "Noisiest processes") {
            let top = s.noisiestProcesses(5)
            if top.isEmpty { Text("No errors or faults in this window.").foregroundStyle(p.dim) }
            ForEach(top) { t in
                HStack(spacing: 10) {
                    Text(t.process).frame(width: 200, alignment: .leading).lineLimit(1)
                    VFDMeter(fraction: t.share, segments: 30, height: 8).frame(width: 220)
                    Text("\(Int((t.share * 100).rounded()))%").frame(width: 44, alignment: .trailing)
                    Text("\(t.count.formatted()) msgs · \(t.subsystems) subsystem\(t.subsystems == 1 ? "" : "s")" + (t.faults > 0 ? " · \(t.faults) faults" : ""))
                        .foregroundStyle(p.dim)
                    Spacer()
                }.font(.system(size: 11, design: .monospaced))
                .contentShape(Rectangle()).onTapGesture { filter = t.process }
            }
        }
    }

    private func groupList(_ s: LogSummary, from: Date, to: Date, bucket: TimeInterval, slots: Int) -> some View {
        let groups = s.groups(matching: filter)
        return Panel(title: "By process and subsystem", trailing: filter.isEmpty ? "\(groups.count) groups" : "\(groups.count) of \(s.groups.count) match") {
            ForEach(groups.prefix(Self.maxRows)) { g in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.process).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(g.subsystem.isEmpty ? "no subsystem" : g.subsystem).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Sparkline(values: g.sparkline(from: from, to: to, bucketWidth: bucket, slots: slots), color: g.faults > 0 ? p.warn : p.accent)
                        .frame(width: 140, height: 18)
                    Text(g.count.formatted()).font(.system(size: 12, design: .monospaced)).frame(width: 64, alignment: .trailing)
                    Text(g.faults > 0 ? "\(g.faults) F" : "").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.warn).frame(width: 44, alignment: .trailing)
                }
                .padding(.vertical, 3).padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected == g.id ? p.accent.opacity(0.15) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { selected = g.id }
            }
            if groups.count > Self.maxRows {
                Text("\(groups.count - Self.maxRows) smaller groups not shown; use the filter to find them.").font(.caption).foregroundStyle(p.dim)
            }
        }
    }

    /// Sample messages of the selected group: its distinct messages (kept for every group), then recent occurrences
    /// from the newest entries kept in memory.
    private func detail(_ s: LogSummary) -> some View {
        let g = s.groups.first { $0.id == selected } ?? s.groups(matching: filter).first
        return Panel(title: g.map { "\($0.process) · \($0.subsystem.isEmpty ? "no subsystem" : $0.subsystem)" } ?? "Messages") {
            if let g {
                Text("\(g.count.formatted()) messages, \(g.faults) faults · first \(g.first.formatted(date: .omitted, time: .standard)), last \(g.last.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                ForEach(g.samples.sorted { $0.last > $1.last }, id: \.message) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(m.level == .fault ? "FAULT" : "ERROR") · \(m.count)× · last \(m.last.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(m.level == .fault ? p.warn : p.dim)
                        Text(m.message).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 2)
                }
            } else {
                Text("Click a group to see its messages.").foregroundStyle(p.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Live tail

    private var tailPanel: some View {
        let entries = model.tail.map { t in
            filter.isEmpty ? Array(t.entries.prefix(100)) : Array(t.entries.lazy.filter {
                $0.process.localizedCaseInsensitiveContains(filter) || $0.subsystem.localizedCaseInsensitiveContains(filter)
                    || $0.message.localizedCaseInsensitiveContains(filter) }.prefix(100))
        } ?? []
        let state = model.tailError.map { "stopped: \($0)" } ?? (model.tailRunning ? "following · \(model.tail?.total.formatted() ?? "0") since start" : "paused while no window is visible")
        return Panel(title: "Live tail", trailing: state) {
            if entries.isEmpty { Text(model.tailRunning ? "Waiting for errors and faults…" : "Not running.").foregroundStyle(p.dim) }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(e.time.formatted(date: .omitted, time: .standard)).foregroundStyle(p.dim).frame(width: 80, alignment: .leading)
                    Text(e.level == .fault ? "F" : "E").foregroundStyle(e.level == .fault ? p.warn : p.dim)
                    Text(e.process).frame(width: 150, alignment: .leading).lineLimit(1)
                    Text(e.message).lineLimit(2).textSelection(.enabled)
                }.font(.system(size: 10, design: .monospaced))
            }
        }
    }
}

/// Tiny bar sparkline, scaled to its own maximum; an all-zero series draws nothing.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            guard let mx = values.max(), mx > 0, !values.isEmpty else { return }
            let w = size.width / CGFloat(values.count)
            for (i, v) in values.enumerated() where v > 0 {
                // At least 1 pt tall, so a single message in a bucket stays visible.
                let h = max(1, CGFloat(v / mx) * size.height)
                ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(w - 0.5, 0.5), height: h)), with: .color(color))
            }
        }
    }
}
