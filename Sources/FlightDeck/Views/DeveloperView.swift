import SwiftUI
import AppKit
import FlightDeckCore

// The Developer destination, for people who code on this Mac: dev servers listening on ports, containers, Homebrew
// services, running builds ("is my build what's heating the Mac?"), booted simulators, installed toolchains and a
// "what's using port N?" finder. State and refresh policy live in DeveloperModel; the panels are split across
// DeveloperView, DeveloperPanels and DeveloperToolPanels.

struct DeveloperView: View {
    @Environment(\.palette) var p
    @EnvironmentObject var engine: Engine
    @StateObject var model = DeveloperModel()

    /// The live sample, or nil while replaying a recording (whose processes are from another time, so joining them
    /// with today's dev servers would mislabel them).
    var live: Snapshot? { engine.mode == .replay ? nil : engine.current }

    var body: some View {
        MaybeScroll {
            VStack(spacing: 12) {
                header
                if let n = model.notice {
                    Text(n).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.accent).frame(maxWidth: .infinity, alignment: .leading)
                }
                BuildHeatPanel(model: model, snap: live)
                DevServersPanel(model: model, snap: live)
                ContainersPanel(model: model, snap: live)
                BrewServicesPanel(model: model)
                HStack(alignment: .top, spacing: 12) {
                    BuildsPanel(model: model, snap: live, replaying: engine.mode == .replay)
                    SimulatorsPanel(model: model, snap: live)
                }
                PortFinderPanel(model: model)
                ToolchainsPanel(model: model)
            }.padding(16)
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .alert(model.confirm?.title ?? "", isPresented: Binding(get: { model.confirm != nil }, set: { if !$0 { model.confirm = nil } })) {
            if let c = model.confirm {
                Button(c.button, role: c.destructive ? .destructive : nil) { c.perform() }
                Button("Cancel", role: .cancel) {}
            }
        } message: { Text(model.confirm?.message ?? "") }
    }

    var header: some View {
        HStack {
            Text(model.demo ? "Demo mode: invented dev servers, containers and services. Nothing is run."
                 : "Your developer tools on this Mac. Refreshes every 5 s while this page is open; nothing runs when it's closed.")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
            Spacer()
            if !model.busy.isEmpty { ProgressView().controlSize(.small) }
            Button("Refresh") { model.refreshAll() }.disabled(model.demo)
        }
    }
}

/// Small shared bits for the Developer panels.
enum DevUI {
    static let font = Font.system(size: 11, design: .monospaced)
    static func cpu(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0) } ?? "—" }
    static func mem(_ v: UInt64?) -> String { v.map { Fmt.bytes($0) } ?? "—" }
    static func since(_ d: Date) -> String { Fmt.duration(max(0, Date().timeIntervalSince(d))) }
    /// "~/Projects/app" for paths in the home folder.
    static func short(_ path: String) -> String {
        let h = NSHomeDirectory()
        return path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
    }
}

/// An icon-only borderless button with a tooltip, the style used for row actions.
struct DevIconButton: View {
    var symbol: String
    var help: String
    var disabled = false
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol) }.buttonStyle(.borderless).help(help).disabled(disabled)
    }
}

/// Top readout strip: how much of the Mac the developer tools are using right now, and whether it's running hot.
struct BuildHeatPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: DeveloperModel
    var snap: Snapshot?

    var body: some View {
        let builds = model.builds(snap)
        let buildCPU = builds.reduce(0) { $0 + $1.cpu }
        let engineCPU = model.engines(snap).reduce(0) { $0 + $1.cpu }
        // Per-process CPU is % of one core; the machine's capacity is 100% per logical core.
        let cores = Double(snap?.cpu.cores.count ?? 0)
        let share: Double? = cores > 0 && snap != nil ? min(1, (buildCPU + engineCPU) / (cores * 100)) : nil
        let thermal = snap.map { ["Nominal", "Fair", "Serious", "Critical"][min(max($0.power.thermalState, 0), 3)] }
        Panel(title: "Developer load", trailing: builds.isEmpty ? "no build running" : "build running for \(DevUI.since(builds.map(\.since).min() ?? Date()))") {
            HStack(alignment: .top, spacing: 28) {
                Readout(label: "Dev servers", value: model.servers.map { "\($0.servers.count)" })
                Readout(label: "Containers up", value: runningContainers)
                Readout(label: "Build CPU", value: snap == nil ? nil : String(format: "%.0f", buildCPU), unit: "% core")
                Readout(label: "Container engine", value: snap == nil ? nil : String(format: "%.0f", engineCPU), unit: "% core")
                Readout(label: "Thermal state", value: thermal, color: (snap?.power.thermalState ?? 0) >= 2 ? p.crit : nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SHARE OF THIS MAC'S CPU").font(.meterLabel).foregroundStyle(p.dim)
                    VFDMeter(fraction: share, segments: 30).frame(width: 220)
                    Text(heatLine(builds: builds, share: share)).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).lineLimit(2)
                }
                Spacer()
            }
        }
    }

    var runningContainers: String? {
        guard case .ok(_, let c, _, _)? = model.docker else { return nil }
        return "\(c.filter(\.isRunning).count)/\(c.count)"
    }

    /// The plain-language verdict: is a build what's making the Mac work?
    func heatLine(builds: [BuildActivity], share: Double?) -> String {
        guard let share else { return "Live CPU isn't available while replaying a recording." }
        guard let top = builds.first else { return "No build running. Builds and the container engine together: \(Int(share * 100))% of the CPU." }
        let verdict = share >= 0.5 ? "Your build is what's heating the Mac" : share >= 0.2 ? "Your build is a large part of the load" : "Builds are a small part of the load"
        return "\(verdict): \(top.tool) leads with \(Int(top.cpu))% of one core."
    }
}

/// Dev servers: port, URL, project folder, uptime, CPU, memory and actions for each recognised dev tool.
struct DevServersPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: DeveloperModel
    var snap: Snapshot?

    var body: some View {
        Panel(title: "Dev servers", trailing: model.servers.map { "\($0.servers.count) listening · scanned \($0.time.formatted(date: .omitted, time: .standard))" }) {
            if let scan = model.servers {
                if case .failed(let why) = scan.coverage { Text("Couldn't list listening ports: \(why).").font(DevUI.font).foregroundStyle(.orange) }
                if scan.servers.isEmpty {
                    Text("No developer tool of yours is listening on a TCP port.").font(DevUI.font).foregroundStyle(p.dim)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow { ForEach(["Tool", "Port", "URL", "Project folder", "Uptime", "CPU", "Memory", ""], id: \.self) { Text($0).font(.meterLabel).foregroundStyle(p.dim) } }
                        ForEach(scan.servers) { s in row(s) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !scan.otherOwnListeners.isEmpty {
                    Text("Also listening, not recognised as dev tools: \(scan.otherOwnListeners.joined(separator: ", ")). Other users' and system processes are not listed here.")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).lineLimit(2)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder func row(_ s: DevServer) -> some View {
        let u = model.usage(s, in: snap)
        let port = s.ports.first ?? 0
        GridRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(s.kind.name).foregroundStyle(p.text)
                Text(verbatim: "\(s.kind.family.rawValue) · PID \(s.identity.pid)").font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim)
            }.help(s.arguments.joined(separator: " "))
            Text(s.ports.map(String.init).joined(separator: ", ")).monospacedDigit()
                .foregroundStyle(s.exposure == .allInterfaces ? .orange : p.text)
                .help(s.exposure == .allInterfaces ? "Bound to all interfaces: other devices on the network can connect" : "Bound to \(s.address)")
            if let url = s.url(port: port) {
                Link(url.absoluteString, destination: url).disabled(model.demo)
            } else { Text("—") }
            switch s.projectFolder {
            case .value(let f): Text(DevUI.short(f)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .leading).textSelection(.enabled)
            case .unavailable(let why): Text("— (\(why))").foregroundStyle(p.dim)
            }
            Text(DevUI.since(s.startDate)).monospacedDigit()
            Text(u.map { DevUI.cpu($0.cpu) } ?? "—").monospacedDigit().help(u == nil ? "Not in the current process sample yet" : "")
            Text(DevUI.mem(u?.memory)).monospacedDigit()
            HStack(spacing: 8) {
                DevIconButton(symbol: "globe", help: "Open \(s.url(port: port)?.absoluteString ?? "") in the browser", disabled: model.demo) {
                    if let url = s.url(port: port) { NSWorkspace.shared.open(url) }
                }
                DevIconButton(symbol: "folder", help: "Reveal the project folder in Finder", disabled: model.demo || s.projectFolder.value == nil) {
                    if let f = s.projectFolder.value { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)]) }
                }
                DevIconButton(symbol: "info.circle", help: "Inspect the process", disabled: AppActions.openInspector == nil) {
                    AppActions.openInspector?(s.identity)
                }
                DevIconButton(symbol: "stop.circle", help: "Stop (SIGTERM, after confirmation)", disabled: model.demo) { model.askStop(s) }
            }
        }.font(DevUI.font)
    }
}
