import SwiftUI
import Combine
import FlightDeckCore
// Process Inspector window (opened via AppActions.openInspector from Processes, findings and the menu bar).
// `InspectorModel` tracks one process across live samples; `InspectorView` shows its graphs (from Engine's
// ProcessHistory), kernel details from ProcessInspector (open files, sockets, threads, environment, signature),
// on-demand call-stack sampling, and identity-checked actions.

/// Follows one process (by identity, so a recycled PID is never confused with it) across live samples.
/// Always follows `engine.liveSnapshot`, never the replayed snapshot: the inspector is about a process running now,
/// so it keeps updating even while the main window replays a recording.
@MainActor
final class InspectorModel: ObservableObject {
    let identity: ProcessIdentity
    /// Latest sample of the process; keeps the last value seen after the process exits so the window stays readable.
    @Published private(set) var sample: ProcessSample?
    /// True once the process is gone from samples and its PID now has a different (or no) identity.
    @Published private(set) var exited = false
    /// One slot per sample tick from Engine.processHistory; nil slots are ticks with no data (gaps).
    @Published private(set) var history: [ProcessHistory.Point?] = []
    /// Slow-to-gather details (files, threads, environment, signature, counters); nil until the first load finishes.
    @Published private(set) var details: ProcessDetails?
    /// Previous counters, for per-second rates.
    @Published private(set) var previousCounters: ProcessDetails.Counters?
    /// Direct children of this process in the latest snapshot.
    @Published private(set) var children: [ProcessSample] = []
    /// Output of the last `/usr/bin/sample` run, if any.
    @Published var stacks: String?
    @Published var sampling = false
    private var bag: AnyCancellable?
    private var lastDetails = Date.distantPast
    private weak var engine: Engine?

    init(identity: ProcessIdentity, engine: Engine) {
        self.identity = identity; self.engine = engine
        history = engine.processHistory.series(identity)
        sample = engine.liveSnapshot?.processes.first { $0.identity == identity }
        bag = engine.$liveSnapshot.compactMap { $0 }.sink { [weak self] s in self?.ingest(s) }
        refreshDetails()
    }

    /// Called for every live snapshot on the main actor (via the Combine sink in init).
    private func ingest(_ s: Snapshot) {
        let p = s.processes.first { $0.identity == identity }
        // Missing from one snapshot isn't proof of exit, so confirm by re-reading the PID's identity: only a different
        // start time (PID recycled) or no process at all counts as exited.
        if p == nil { exited = ProcessSampler.identity(of: identity.pid) != identity }
        if let p { sample = p; exited = false }
        history = engine?.processHistory.series(identity) ?? []
        // A child must have started after this process; an older process with the same ppid would be a leftover from a
        // previous owner of the PID.
        children = s.processes.filter { $0.ppid == identity.pid && $0.identity.startTime >= identity.startTime }
        // Details are relatively expensive (proc_pidinfo over every fd and thread, codesign check), so refresh at most
        // every 3 s rather than every sample.
        if Date().timeIntervalSince(lastDetails) >= 3 { refreshDetails() }
    }

    /// Gathers ProcessDetails on a detached utility task and publishes it on the main actor. The previous counters are
    /// kept so StatisticsPanel can show per-second rates. Skipped once the process has exited.
    func refreshDetails() {
        lastDetails = Date()
        guard !exited else { return }
        let pid = identity.pid, path = sample?.path ?? ""
        Task.detached(priority: .utility) {
            let d = ProcessInspector.details(pid: pid, path: path)
            await MainActor.run { self.previousCounters = self.details?.counters; self.details = d }
        }
    }

    /// Runs `/usr/bin/sample` for `seconds` off the main actor; the result lands in `stacks`. Without root this only
    /// works for the user's own processes; otherwise `stacks` holds an explanation rather than a report.
    func sampleStacks(seconds: Int) {
        sampling = true
        let pid = identity.pid
        Task.detached(priority: .userInitiated) {
            let out = ProcessInspector.sampleStacks(pid: pid, seconds: seconds)
            await MainActor.run { self.stacks = out; self.sampling = false }
        }
    }

    /// Projects one metric out of the history into graph values, preserving nil gaps.
    func series(_ f: (ProcessHistory.Point) -> Float?) -> [Double?] { history.map { $0.flatMap(f).map(Double.init) } }
}

/// Lower tabs of the inspector; only the selected one is built.
enum InspectorTab: String, CaseIterable, Identifiable {
    case overview = "Overview", files = "Open Files", network = "Network", threads = "Threads", environment = "Environment", stacks = "Stacks", memory = "Memory"
    var id: String { rawValue }
}

/// Window-group root: builds the model for the identity the window was opened with.
struct InspectorWindow: View {
    @EnvironmentObject var e: Engine
    var identity: ProcessIdentity?
    var body: some View {
        if let identity { InspectorView(model: InspectorModel(identity: identity, engine: e)) }
        else { Text("No process selected").frame(width: 400, height: 200) }
    }
}

/// The inspector UI: header with actions, five history graphs, then the selected detail tab. Fields the process
/// doesn't expose (other users' or protected processes) show "—" or an explanation instead of a guessed value.
struct InspectorView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @StateObject var model: InspectorModel
    @State private var tab: InspectorTab = .overview
    @State private var filter = ""
    /// Pending confirmation for a destructive signal: (signal, verb shown in the alert).
    @State private var confirm: (Int32, String)?
    @State private var error: String?

    var body: some View {
        let s = model.sample
        VStack(spacing: 0) {
            header(s)
            // MaybeScroll so the window still renders in off-screen captures, where a ScrollView draws empty.
            MaybeScroll {
                VStack(spacing: 12) {
                    graphs
                    Picker("", selection: $tab) { ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                    switch tab {
                    case .overview: overview(s)
                    case .files: filesTab
                    case .network: networkTab(s)
                    case .threads: threadsTab
                    case .environment: environmentTab
                    case .stacks: stacksTab
                    case .memory: MemoryBreakdownPanel(model: model)
                    }
                }.padding(14)
            }
        }
        .background(p.background)
        .navigationTitle("\(s?.name ?? "Process") (\(model.identity.pid))")
        .frame(minWidth: 760, minHeight: 600)
        // The command palette's "Sample Stacks" asks this window (new or already open) to sample; the request is
        // consumed so it runs once. @Published emits its current value on subscription, which covers a new window.
        .onReceive(PowerTools.shared.$stackRequest) { r in
            guard r == model.identity else { return }
            PowerTools.shared.stackRequest = nil; tab = .stacks
            if !model.sampling { model.sampleStacks(seconds: 3) }
        }
        .alert("\(confirm?.1 ?? "") “\(s?.name ?? "")”?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirm?.1 ?? "OK", role: .destructive) { if let c = confirm { send(c.0) }; confirm = nil }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: { Text("PID \(model.identity.pid). Unsaved work in this process may be lost.") }
        .alert("Action failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }

    /// Sends a signal via ProcessSampler.send, which re-checks PID + start time first so a recycled PID is never hit.
    func send(_ sig: Int32) { do { try ProcessSampler.send(sig, to: model.identity) } catch { self.error = error.localizedDescription } }

    @ViewBuilder func header(_ s: ProcessSample?) -> some View {
        HStack(spacing: 14) {
            AppIcon(path: s?.path ?? "").frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(s?.name ?? "—").font(.system(size: 17, weight: .semibold))
                    if model.exited { Text("EXITED").font(.caption.bold()).padding(.horizontal, 6).background(Capsule().fill(p.crit.opacity(0.3))) }
                    if let sig = model.details?.signature {
                        Label(sig.summary, systemImage: sig.valid ? "checkmark.seal" : "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(sig.valid ? p.dim : p.warn)
                    }
                }
                Text(s?.path.isEmpty == false ? s!.path : "path unavailable").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(p.dim).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer()
            // Quit and Force Quit ask for confirmation; Suspend/Resume and renice are reversible so they act at once.
            // The whole menu is disabled once the process has exited.
            Menu("Actions") {
                Button("Quit") { confirm = (SIGTERM, "Quit") }
                Button("Force Quit") { confirm = (SIGKILL, "Force Quit") }
                Divider()
                Button("Suspend") { send(SIGSTOP) }
                Button("Resume") { send(SIGCONT) }
                Divider()
                Button("Lower Priority (nice 10)") { renice(10) }
                Button("Background Priority (nice 20)") { renice(20) }
                Divider()
                Button("Sample Stacks (3 s)") { tab = .stacks; model.sampleStacks(seconds: 3) }
                Button("Reveal in Finder") { if let s { NSWorkspace.shared.selectFile(s.path, inFileViewerRootedAtPath: "") } }.disabled(s?.path.isEmpty ?? true)
                Button("Copy Summary") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summaryText(s), forType: .string) }
            }.frame(width: 100).disabled(model.exited)
        }
        .padding(14).background(p.panel).overlay(alignment: .bottom) { Divider() }
    }

    /// Raises the nice value (lower priority). Lowering it again, or touching another user's process, needs root.
    func renice(_ v: Int32) {
        do { try ProcessInspector.setNice(pid: model.identity.pid, v); model.refreshDetails() }
        catch { self.error = "Couldn't change priority: \(error.localizedDescription). Other users' processes need root." }
    }

    /// CPU (% of one core), memory (bytes), GPU (% of GPU time), disk and network (bytes/s) over the inspector history.
    /// `minHeadroom` keeps a near-idle process from filling the graph with noise (e.g. at least 10% or 1 MB of y-range).
    var graphs: some View {
        let s = model.sample
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            Panel(title: "CPU", trailing: s.map { String(format: "%.1f%% · %d threads", $0.cpu, $0.threads) }) {
                HistoryGraph(traces: [GraphTrace(name: "cpu", values: model.series { $0.cpu }, color: p.accent)], minHeadroom: 10,
                             format: { String(format: "%.0f%%", $0) }).frame(height: 90)
            }
            Panel(title: "Memory", trailing: s.map { Fmt.bytes($0.memory) }) {
                HistoryGraph(traces: [GraphTrace(name: "mem", values: model.series { $0.memory }, color: p.accent)], minHeadroom: 1_048_576,
                             format: Fmt.bytes).frame(height: 90)
            }
            Panel(title: "GPU", trailing: s?.gpu.map { String(format: "%.1f%% of GPU time", $0) } ?? "not using the GPU") {
                HistoryGraph(traces: [GraphTrace(name: "gpu", values: model.series { $0.gpu }, color: p.accent2)], minHeadroom: 10,
                             format: { String(format: "%.0f%%", $0) }).frame(height: 90)
            }
            Panel(title: "Disk", trailing: s.map { "R \(Fmt.rate($0.diskReadBps)) · W \(Fmt.rate($0.diskWriteBps))" }) {
                HistoryGraph(traces: [GraphTrace(name: "r", values: model.series { $0.diskRead }, color: p.accent),
                                      GraphTrace(name: "w", values: model.series { $0.diskWrite }, color: p.accent2)], minHeadroom: 65_536,
                             format: Fmt.rate).frame(height: 90)
            }
            Panel(title: "Network", trailing: s?.network.map { "↓ \(Fmt.rate($0.inBps)) · ↑ \(Fmt.rate($0.outBps))" } ?? "—") {
                HistoryGraph(traces: [GraphTrace(name: "in", values: model.series { $0.netIn }, color: p.accent),
                                      GraphTrace(name: "out", values: model.series { $0.netOut }, color: p.accent2)], minHeadroom: 16_384,
                             format: Fmt.rate).frame(height: 90)
            }
        }
    }

    /// Overview tab: identity and totals from the sample, plus details (nice, cwd, arguments), kernel statistics,
    /// code signature and the process tree.
    @ViewBuilder func overview(_ s: ProcessSample?) -> some View {
        let d = model.details
        Panel(title: "Process") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                row("PID / parent", s.map { "\($0.pid) / \($0.ppid)" })
                row("User", s.map { "\($0.user) (uid \($0.uid))" })
                row("Started", s.map { "\($0.startDate.formatted(date: .abbreviated, time: .standard)) · running \(Fmt.duration(Date().timeIntervalSince($0.startDate)))" })
                row("CPU time", s.map { Fmt.duration($0.cpuTime) })
                row("Energy", s?.energyWatts.map { String(format: "%.2f W", $0) })
                row("Idle wake-ups", s.map { String(format: "%.0f /s", $0.wakeups) })
                // Disk counters of restricted (other-user/protected) processes can't be read, so show "—" rather than 0.
                row("Disk total", s.map { $0.restricted ? nil : "read \(Fmt.bytes($0.diskRead)) · written \(Fmt.bytes($0.diskWritten))" } ?? nil)
                row("Network total", s?.network.map { "↓ \(Fmt.bytes($0.totalIn)) · ↑ \(Fmt.bytes($0.totalOut)) · \($0.connections) connections" })
                row("Priority (nice)", d?.nice.map { "\($0)" })
                row("Working directory", d?.cwd.value)
                row("Arguments", d?.arguments.value?.joined(separator: " "))
            }.font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        }
        if let c = d?.counters { StatisticsPanel(c: c, prev: model.previousCounters, s: s) }
        if let sig = d?.signature {
            Panel(title: "Code signature") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    row("Status", sig.summary)
                    row("Identifier", sig.identifier)
                    row("Team", sig.teamID)
                    row("Chain", sig.authority.joined(separator: " → "))
                    row("Hardened runtime", sig.hardenedRuntime ? "yes" : "no")
                }.font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
        }
        Panel(title: "Ancestry and children") {
            VStack(alignment: .leading, spacing: 4) {
                // ProcessDetails lists ancestry from this process up to launchd; reversed, launchd prints first and each
                // generation is indented one step. Children are clickable and open their own inspector.
                ForEach(Array((d?.ancestry ?? []).reversed().enumerated()), id: \.offset) { i, a in
                    Text(String(repeating: "  ", count: i) + "└ \(a.name) (\(a.pid))").foregroundStyle(a.pid == model.identity.pid ? p.text : p.dim)
                }
                ForEach(model.children) { c in
                    Button { AppActions.openInspector?(c.identity) } label: {
                        Text(String(repeating: "  ", count: d?.ancestry.count ?? 1) + "└ \(c.name) (\(c.pid)) · \(String(format: "%.0f%%", c.cpu)) · \(Fmt.bytes(c.memory))")
                    }.buttonStyle(.plain).foregroundStyle(p.accent)
                }
            }.font(.system(size: 12, design: .monospaced))
        }
    }

    /// Label/value grid row; nil values render as "—" (unavailable), never as an empty or zero value.
    func row(_ k: String, _ v: String?) -> some View {
        GridRow {
            Text(k).foregroundStyle(p.dim)
            Text(v ?? "—").foregroundStyle(p.text).lineLimit(4)
        }
    }

    /// Explanation shown when a detail list couldn't be read, instead of an empty table.
    func unavailable(_ what: String) -> some View {
        Text("\(what) can't be read for this process: it belongs to another user or is protected by macOS. Nothing is guessed.")
            .foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
    }

    var filterField: some View {
        TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
    }

    // The tabs below share one pattern: data present → table; details loaded but this field unavailable →
    // explanation; details not loaded yet → spinner.
    @ViewBuilder var filesTab: some View {
        if let files = model.details?.files.value {
            let shown = files.filter { filter.isEmpty || $0.description.localizedCaseInsensitiveContains(filter) }
            Panel(title: "Open files and descriptors", trailing: "\(files.count) open") {
                filterField
                Table(shown) {
                    TableColumn("FD") { Text("\($0.fd)").monospacedDigit() }.width(50)
                    TableColumn("Type") { Text($0.kind.rawValue) }.width(70)
                    TableColumn("Path / description") { f in Text(f.description).textSelection(.enabled).help(f.description) }
                }.frame(minHeight: 320)
            }
        } else if model.details != nil { unavailable("Open files") } else { ProgressView() }
    }

    @ViewBuilder func networkTab(_ s: ProcessSample?) -> some View {
        // Sockets are derived from the same file-descriptor scan, so they are only trustworthy when that scan succeeded.
        if let socks = model.details?.sockets, model.details?.files.isAvailable == true {
            Panel(title: "Sockets", trailing: "\(socks.count) open") {
                Table(socks) {
                    TableColumn("FD") { Text("\($0.fd)").monospacedDigit() }.width(44)
                    TableColumn("Proto") { Text($0.proto) }.width(50)
                    TableColumn("Local") { Text($0.local).textSelection(.enabled) }
                    TableColumn("Remote") { Text($0.remote.isEmpty ? "—" : $0.remote).textSelection(.enabled) }
                    TableColumn("State") { Text($0.state) }.width(110)
                }.frame(minHeight: 280)
            }
        } else if model.details != nil { unavailable("Sockets") } else { ProgressView() }
        if let s { DestinationsInspectorPanel(process: s) }   // where this app's traffic went (DestinationsSettings.swift)
    }

    @ViewBuilder var threadsTab: some View {
        if let threads = model.details?.threads.value {
            Panel(title: "Threads", trailing: "\(threads.count) threads · refreshed every 3 s") {
                // Busiest threads first; thread IDs are shown in hex as in `sample` and Instruments output.
                Table(threads.sorted { $0.cpu > $1.cpu }) {
                    TableColumn("ID") { Text(String($0.id, radix: 16)).monospacedDigit() }.width(80)
                    TableColumn("Name") { Text($0.name.isEmpty ? "—" : $0.name) }
                    TableColumn("CPU") { Text(String(format: "%.1f%%", $0.cpu)).monospacedDigit() }.width(60)
                    TableColumn("State") { Text($0.state) }.width(110)
                    TableColumn("Priority") { Text("\($0.priority)") }.width(60)
                    TableColumn("User / sys time") { Text(String(format: "%.2f s / %.2f s", $0.userTime, $0.systemTime)).monospacedDigit() }.width(140)
                }.frame(minHeight: 320)
            }
        } else if model.details != nil { unavailable("Threads") } else { ProgressView() }
    }

    @ViewBuilder var environmentTab: some View {
        if let env = model.details?.environment.value {
            Panel(title: "Environment", trailing: "\(env.count) variables") {
                filterField
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(env.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, id: \.self) { v in
                        let parts = v.split(separator: "=", maxSplits: 1).map(String.init)
                        HStack(alignment: .firstTextBaseline) {
                            Text(parts[0]).foregroundStyle(p.accent).frame(width: 220, alignment: .leading)
                            Text(parts.count > 1 ? parts[1] : "").foregroundStyle(p.text).lineLimit(3)
                        }
                    }
                }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
        } else if model.details != nil {
            // macOS exposes a process's environment only to that process itself, so this is expected for every other one.
            Text("macOS doesn't let one app read another process's environment variables, so they can't be shown here (only FlightDeck's own are visible). Nothing is guessed.")
                .foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
        } else { ProgressView() }
    }

    var stacksTab: some View {
        Panel(title: "Call stacks", trailing: "via /usr/bin/sample") {
            HStack {
                Button(model.sampling ? "Sampling…" : "Sample for 3 s") { model.sampleStacks(seconds: 3) }.disabled(model.sampling || model.exited)
                Button("Sample for 10 s") { model.sampleStacks(seconds: 10) }.disabled(model.sampling || model.exited)
                if model.sampling { ProgressView().controlSize(.small) }
                Spacer()
                if let st = model.stacks {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(st, forType: .string) }
                    Button("Save…") {
                        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(model.sample?.name ?? "process")-\(model.identity.pid)-sample.txt"
                        if panel.runModal() == .OK, let u = panel.url { try? st.write(to: u, atomically: true, encoding: .utf8) }
                    }
                }
            }
            Text("Samples every thread's call stack for a few seconds and shows where the time goes. This is how to find out why an app is busy or hung.")
                .font(.caption).foregroundStyle(p.dim)
            if let st = model.stacks {
                ScrollView(.horizontal) {
                    Text(st).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).fixedSize()
                }.frame(minHeight: 360)
            }
        }
    }

    /// Plain-text summary for the clipboard (Actions › Copy Summary).
    func summaryText(_ s: ProcessSample?) -> String {
        guard let s else { return "" }
        // Never the helper's contents of another user's process (they are live-only).
        return ProcessSummaryText.make(s, details: model.details)
    }
}

/// Activity Monitor-style statistics with rates (per second, over the last refresh).
/// Rates are per second between the two most recent detail refreshes (≈3 s apart); blank on the first refresh or if a
/// counter went backwards. Optional counters (peak footprint, instructions/cycles, logical writes) show "—" when the
/// kernel didn't report them.
struct StatisticsPanel: View {
    /// What "not translated" means on this Mac: Apple silicon code, or plain Intel code on an Intel Mac.
    static let nativeArch: String = (Sysctl.int("hw.optional.arm64") ?? 0) == 1 ? "Apple silicon" : "Intel (native)"
    @Environment(\.palette) var p
    var c: ProcessDetails.Counters
    var prev: ProcessDetails.Counters?
    var s: ProcessSample?

    func rate(_ k: KeyPath<ProcessDetails.Counters, Int64>) -> String {
        guard let prev, c.time > prev.time else { return "" }
        let r = Double(c[keyPath: k] - prev[keyPath: k]) / c.time.timeIntervalSince(prev.time)
        return r >= 0 ? String(format: "  (%.0f/s)", r) : ""
    }
    func n(_ v: Int64) -> String { v.formatted(.number) }

    var body: some View {
        Panel(title: "Statistics", trailing: "kernel counters since launch (rate over the last 3 s)") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow { Text("Page faults").foregroundStyle(p.dim); Text(n(c.faults) + rate(\.faults))
                          Text("Page-ins").foregroundStyle(p.dim); Text(n(c.pageins) + rate(\.pageins)) }
                GridRow { Text("Unix syscalls").foregroundStyle(p.dim); Text(n(c.unixSyscalls) + rate(\.unixSyscalls))
                          Text("Mach syscalls").foregroundStyle(p.dim); Text(n(c.machSyscalls) + rate(\.machSyscalls)) }
                GridRow { Text("Context switches").foregroundStyle(p.dim); Text(n(c.contextSwitches) + rate(\.contextSwitches))
                          Text("Copy-on-write faults").foregroundStyle(p.dim); Text(n(c.cowFaults) + rate(\.cowFaults)) }
                GridRow { Text("Mach msgs sent").foregroundStyle(p.dim); Text(n(c.machMessagesSent) + rate(\.machMessagesSent))
                          Text("Mach msgs received").foregroundStyle(p.dim); Text(n(c.machMessagesReceived) + rate(\.machMessagesReceived)) }
                GridRow { Text("Resident / virtual").foregroundStyle(p.dim); Text("\(Fmt.bytes(c.residentBytes)) / \(Fmt.bytes(c.virtualBytes))")
                          Text("Peak memory").foregroundStyle(p.dim); Text(c.peakFootprint.map { Fmt.bytes($0) } ?? "—") }
                GridRow { Text("Instructions / cycles").foregroundStyle(p.dim)
                          Text(c.instructions.flatMap { i in c.cycles.map { cy in String(format: "IPC %.2f", Double(i) / Double(max(cy, 1))) } } ?? "—")
                          Text("Logical writes").foregroundStyle(p.dim); Text(c.logicalWrites.map { Fmt.bytes($0) } ?? "—") }
                GridRow { Text("Running threads").foregroundStyle(p.dim); Text("\(c.runningThreads) of \(s?.threads ?? 0)")
                          Text("Kind").foregroundStyle(p.dim); Text(s?.translated == true ? "Intel (Rosetta 2)" : s?.translated == false ? StatisticsPanel.nativeArch : "—") }
                if let a = s?.powerAssertions, !a.isEmpty {
                    GridRow { Text("Keeping awake").foregroundStyle(p.dim); Text(a.map { "\($0.label)" + ($0.name.isEmpty ? "" : " (“\($0.name)”)") }.joined(separator: "; ")).gridCellColumns(3) }
                }
            }.font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        }
    }
}
