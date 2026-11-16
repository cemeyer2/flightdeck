// The inspector's "Memory" tab: an on-demand breakdown of what the process's memory is made of, from
// `/usr/bin/footprint` (or `vmmap --summary`), parsed in core by MemoryBreakdownReader. Nothing runs until the user
// asks; it only works for the user's own processes, and says so plainly otherwise.
import SwiftUI
import FlightDeckCore

struct MemoryBreakdownPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: InspectorModel
    /// The last result (nil until analysed). Settable from outside so UIBench can render a real result.
    @State var result: Result<MemoryBreakdown, MemoryBreakdownReader.Failure>?
    @State private var running = false

    /// Unknown owner (no sample yet) is allowed to try; the tools then report failure themselves.
    var ownProcess: Bool { model.sample.map { $0.uid == getuid() } ?? true }

    /// Runs the tools on a detached task (footprint ≈ 0.1 s, vmmap up to several seconds on a big app).
    func analyze() {
        running = true
        let pid = model.identity.pid, own = ownProcess
        Task {
            let r = await Task.detached(priority: .userInitiated) { MemoryBreakdownReader.read(pid: pid, ownedByUser: own) }.value
            result = r; running = false
        }
    }

    var body: some View {
        Panel(title: "Memory breakdown", trailing: resultSource) {
            if !ownProcess && getuid() != 0 {
                Text("Not available for this process: it belongs to another user, and macOS only lets footprint and vmmap read your own processes (without root). Nothing is guessed.")
                    .foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Button(running ? "Analysing…" : (result == nil ? "Analyse Memory" : "Analyse Again")) { analyze() }
                        .disabled(running || model.exited)
                    if running { ProgressView().controlSize(.small) }
                    Spacer()
                }
                Text("Runs Apple's footprint tool once (vmmap if that fails) and groups the process's memory by kind. Dirty memory was written by the process and must stay in RAM or be compressed/swapped; clean memory can be dropped and re-read from disk.")
                    .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                switch result {
                case .success(let b): breakdown(b)
                case .failure(.notOwnProcess):
                    Text("Not available: macOS only lets these tools read your own processes.").foregroundStyle(p.dim)
                case .failure(.toolFailed(let why)):
                    Text("Not available: \(why)").foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                case .none: EmptyView()
                }
            }
        }
    }

    var resultSource: String? {
        if case .success(let b) = result { return "via \(b.source.rawValue)" }
        return "on demand · your own processes only"
    }

    @ViewBuilder func breakdown(_ b: MemoryBreakdown) -> some View {
        HStack(spacing: 28) {
            Readout(label: "Footprint", value: b.footprint.map { Fmt.bytes($0) }, size: 17)
            Readout(label: "Peak", value: b.peak.map { Fmt.bytes($0) }, size: 17)
            Readout(label: "Dirty (in RAM)", value: b.totalDirty.map { Fmt.bytes($0) }, size: 17)
            Readout(label: "Compressed / swapped", value: b.totalSwapped.map { Fmt.bytes($0) }, size: 17)
            Readout(label: "Clean (in RAM)", value: b.totalClean.map { Fmt.bytes($0) }, size: 17)
        }
        let groups = b.groups
        // Bars share one scale: the biggest group's footprint (dirty + swapped), or its clean size if that's larger.
        let scale = Double(max(groups.map { max($0.footprint, $0.clean ?? 0) }.max() ?? 1, 1))
        HStack(spacing: 14) {
            legend(p.accent, "dirty"); legend(p.accent2, "compressed / swapped"); legend(p.dim.opacity(0.5), "clean")
            Spacer()
        }.font(.caption)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(g.group.rawValue).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(values(dirty: g.dirty, swapped: g.swapped, clean: g.clean)).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                    }
                    bar(dirty: g.dirty, swapped: g.swapped, clean: g.clean, scale: scale).frame(height: 10)
                    // The biggest tool categories inside the group, by name as footprint/vmmap print them.
                    Text(g.categories.prefix(4).filter { $0.footprint > 0 || ($0.clean ?? 0) > 0 }
                        .map { "\($0.name) \(Fmt.bytes($0.footprint > 0 ? $0.footprint : $0.clean ?? 0))" }.joined(separator: " · "))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).lineLimit(1)
                }
            }
        }
        if b.source == .vmmap {
            Text("From vmmap: totals may differ slightly from the Memory column, which uses the kernel's footprint figure.")
                .font(.caption).foregroundStyle(p.dim)
        }
    }

    func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 8); Text(s).foregroundStyle(p.dim) }
    }

    /// "dirty 1.2 GB · swapped 300 MB · clean 40 MB"; columns the tool didn't report are left out rather than shown as 0.
    func values(dirty: UInt64?, swapped: UInt64?, clean: UInt64?) -> String {
        [dirty.map { "dirty \(Fmt.bytes($0))" }, swapped.map { "swapped \(Fmt.bytes($0))" }, clean.map { "clean \(Fmt.bytes($0))" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Stacked bar: dirty, then swapped, then clean, each as a fraction of `scale`. Unreported parts take no width.
    func bar(dirty: UInt64?, swapped: UInt64?, clean: UInt64?, scale: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let d = CGFloat(Double(dirty ?? 0) / scale) * w, s = CGFloat(Double(swapped ?? 0) / scale) * w
            let c = min(CGFloat(Double(clean ?? 0) / scale) * w, max(w - d - s, 0))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(p.meterOff)
                HStack(spacing: 0) {
                    Rectangle().fill(p.accent).frame(width: d)
                    Rectangle().fill(p.accent2).frame(width: s)
                    Rectangle().fill(p.dim.opacity(0.5)).frame(width: c)
                }.clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
    }
}
