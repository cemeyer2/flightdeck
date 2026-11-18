import SwiftUI
import FlightDeckCore

// Developer destination: running builds, booted simulators, the port finder and installed toolchains.

struct BuildsPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: DeveloperModel
    var snap: Snapshot?
    var replaying: Bool

    var body: some View {
        let builds = model.builds(snap)
        Panel(title: "Builds running", trailing: builds.isEmpty ? nil : "\(builds.reduce(0) { $0 + $1.processes }) processes") {
            if replaying {
                Text("Replaying a recording: live build activity is hidden.").font(DevUI.font).foregroundStyle(p.dim)
            } else if builds.isEmpty {
                Text("No compiler, linker or build tool is running (xcodebuild, swift-frontend, clang, cargo, rustc, Gradle, tsc, esbuild…).")
                    .font(DevUI.font).foregroundStyle(p.dim)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { ForEach(["Tool", "Procs", "CPU", "Memory", "Elapsed"], id: \.self) { Text($0).font(.meterLabel).foregroundStyle(p.dim) } }
                    ForEach(builds) { b in
                        GridRow {
                            Text(b.tool).foregroundStyle(p.text)
                            Text("\(b.processes)").monospacedDigit()
                            HStack(spacing: 6) {
                                // One meter segment per core's worth of CPU, up to 16 cores.
                                VFDMeter(fraction: min(1, b.cpu / 1600), segments: 16, height: 8).frame(width: 80)
                                Text(DevUI.cpu(b.cpu)).monospacedDigit().fixedSize()
                            }
                            Text(DevUI.mem(b.memory)).monospacedDigit()
                            Text(DevUI.since(b.since)).monospacedDigit().help("Since the oldest of these processes started")
                        }.font(DevUI.font)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity)
    }
}

struct SimulatorsPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: DeveloperModel
    var snap: Snapshot?

    var body: some View {
        Panel(title: "Simulators booted") {
            switch model.simulators {
            case nil: ProgressView().controlSize(.small)
            case .noXcode(let why)?: Text("Not available: \(why).").font(DevUI.font).foregroundStyle(p.dim)
            case .failed(let why)?: Text("simctl failed: \(why)").font(DevUI.font).foregroundStyle(.orange).lineLimit(3)
            case .ok(let sims)?:
                if sims.isEmpty {
                    Text("No simulator is booted.").font(DevUI.font).foregroundStyle(p.dim)
                } else {
                    let usage = model.simulatorUsage(sims, snap)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow { ForEach(["Device", "Runtime", "CPU", "Memory"], id: \.self) { Text($0).font(.meterLabel).foregroundStyle(p.dim) } }
                        ForEach(sims) { s in
                            let u = usage[s.udid]
                            GridRow {
                                Text(s.name).foregroundStyle(p.text).help(s.udid)
                                Text(s.runtime)
                                Text(DevUI.cpu(u?.cpu)).monospacedDigit()
                                    .help(u.map { "\($0.processes) processes under this device's launchd_sim" } ?? "This device's launchd_sim wasn't found in the process sample")
                                Text(DevUI.mem(u?.memory)).monospacedDigit()
                            }.font(DevUI.font)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.frame(maxWidth: .infinity)
    }
}

/// "What's using port N?": every listener on the port (all users' processes when netstat shows owners) and any
/// container publishing it, with a jump to the inspector.
struct PortFinderPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: DeveloperModel

    var body: some View {
        Panel(title: "Port finder") {
            HStack {
                Text("What's using port").font(DevUI.font).foregroundStyle(p.dim)
                TextField("3000", text: $model.portQuery).textFieldStyle(.roundedBorder).frame(width: 140).onSubmit { model.findPort() }
                Button("Find") { model.findPort() }
                Spacer()
            }
            if let e = model.portError { Text(e).font(DevUI.font).foregroundStyle(.orange) }
            if let a = model.portAnswer { answer(a) }
        }
    }

    @ViewBuilder func answer(_ a: PortAnswer) -> some View {
        if a.sockets.isEmpty && a.containers.isEmpty {
            Text("Nothing is listening on port \(a.port)" + (a.coverage == .allProcesses ? "." : " among your processes (other users' processes aren't visible: \(coverage(a.coverage)))."))
                .font(DevUI.font).foregroundStyle(p.dim)
        }
        ForEach(a.sockets) { s in
            HStack(spacing: 10) {
                Image(systemName: s.exposure == .allInterfaces ? "exclamationmark.triangle.fill" : s.exposure == .loopback ? "lock" : "network")
                    .foregroundStyle(s.exposure == .allInterfaces ? .orange : p.dim)
                Text(verbatim: "\(s.process) (PID \(s.pid))").foregroundStyle(p.text)
                Text("\(s.proto) \(s.family) \(s.address):\(s.port) · \(s.exposure.rawValue.lowercased())").foregroundStyle(p.dim)
                Button("Inspect") {
                    // Resolve the PID's identity now, so the inspector opens on the process that holds the port today.
                    if let id = ProcessSampler.identity(of: s.pid) { AppActions.openInspector?(id) }
                }.controlSize(.small).disabled(AppActions.openInspector == nil || model.demo)
                Spacer()
            }.font(DevUI.font)
        }
        ForEach(a.containers) { c in
            HStack(spacing: 10) {
                Image(systemName: "shippingbox").foregroundStyle(p.accent)
                Text("Published by container \(c.name) (\(c.image))").foregroundStyle(p.text)
                Text(c.ports).foregroundStyle(p.dim).lineLimit(1)
                Spacer()
            }.font(DevUI.font)
        }
    }

    func coverage(_ c: ListeningScan.Coverage) -> String {
        switch c {
        case .allProcesses: "all processes"
        case .ownProcessesOnly(let why): why
        case .failed(let why): why
        }
    }
}

struct ToolchainsPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: DeveloperModel

    var body: some View {
        Panel(title: "Toolchains", trailing: "probed on open and on Refresh") {
            if let tools = model.toolchains {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow { ForEach(["Tool", "Version", "Path", "Note"], id: \.self) { Text($0).font(.meterLabel).foregroundStyle(p.dim) } }
                    ForEach(tools) { t in
                        GridRow {
                            Text(t.tool).foregroundStyle(p.text)
                            Text(t.version ?? "—").foregroundStyle(t.version == nil ? p.dim : p.accent)
                            Text(t.path.map(DevUI.short) ?? "—").lineLimit(1).truncationMode(.middle).frame(maxWidth: 360, alignment: .leading).textSelection(.enabled)
                            Text(t.note ?? "").foregroundStyle(p.dim).lineLimit(2)
                        }.font(DevUI.font)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text("Only tools found on disk are listed. Version-manager shims (pyenv, rbenv, nodenv, asdf) aren't run; their global version file is read instead.")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}
