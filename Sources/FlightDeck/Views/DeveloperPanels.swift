import SwiftUI
import FlightDeckCore

// Developer destination: the Containers and Homebrew services panels. Both show the tool's own error text when it
// can't answer (engine not running, brew failing) rather than an empty list that would look like "nothing there".

struct ContainersPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: DeveloperModel
    var snap: Snapshot?

    var body: some View {
        Panel(title: "Containers", trailing: trailing) {
            engineLine
            switch model.docker {
            case nil: ProgressView().controlSize(.small)
            case .noCLI?:
                Text("No docker CLI found (looked in Homebrew, /usr/local/bin, Docker Desktop, OrbStack and Rancher Desktop locations).")
                    .font(DevUI.font).foregroundStyle(p.dim)
            case .unreachable(_, let reason)?:
                Text("The container engine didn't answer: \(reason)").font(DevUI.font).foregroundStyle(p.dim).lineLimit(3)
            case .ok(_, let containers, let stats, let statsError)?:
                if let statsError { Text("docker stats failed: \(statsError). Usage is shown as unknown.").font(DevUI.font).foregroundStyle(.orange) }
                if containers.isEmpty {
                    Text("No containers.").font(DevUI.font).foregroundStyle(p.dim)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow { ForEach(["Container", "Image", "Status", "Ports", "CPU", "Memory", "Net I/O", "Block I/O", ""], id: \.self) { Text($0).font(.meterLabel).foregroundStyle(p.dim) } }
                        ForEach(containers) { c in row(c, DockerCLI.stats(for: c, in: stats)) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text("CPU is % of one core, as Docker reports it. Memory is inside the VM, so it is not part of this Mac's process list.")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                }
            }
        }
    }

    var trailing: String? {
        switch model.docker {
        case .ok(let cli, _, _, _)?, .unreachable(let cli, _)?: return DevUI.short(cli)
        default: return nil
        }
    }

    /// The engine's own cost on the Mac (VM and helpers), from the process sample.
    @ViewBuilder var engineLine: some View {
        let engines = model.engines(snap)
        if !engines.isEmpty {
            HStack(spacing: 18) {
                ForEach(engines) { e in
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox").foregroundStyle(p.accent)
                        Text(e.engine).foregroundStyle(p.text)
                        Text("\(DevUI.cpu(e.cpu)) CPU · \(DevUI.mem(e.memory)) · \(e.processes) proc").foregroundStyle(p.dim)
                    }
                }
                Spacer()
            }.font(DevUI.font)
        } else if snap != nil {
            Text("No container engine process (Docker Desktop, OrbStack, Colima, Rancher Desktop) is running.").font(DevUI.font).foregroundStyle(p.dim)
        }
    }

    @ViewBuilder func row(_ c: DockerContainer, _ s: DockerStats?) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).foregroundStyle(p.text).lineLimit(1)
                if let proj = c.composeProject { Text("compose: \(proj)").font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim) }
            }
            Text(c.image).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading)
            Label(c.status, systemImage: c.isRunning ? "circle.fill" : "circle").labelStyle(.titleAndIcon)
                .foregroundStyle(c.isRunning ? p.accent : p.dim).lineLimit(1)
            Text(c.publishedPorts.isEmpty ? "—" : c.publishedPorts.map(String.init).joined(separator: ", ")).help(c.ports)
            // Stats only exist for running containers; a stopped one shows "—" rather than 0.
            Text(DevUI.cpu(s?.cpu)).monospacedDigit()
            Text(s?.memoryBytes.map { Fmt.bytes($0) } ?? "—").monospacedDigit().help(s?.memoryUsage ?? "")
            Text(s?.netIO.isEmpty == false ? s!.netIO : "—").lineLimit(1)
            Text(s?.blockIO.isEmpty == false ? s!.blockIO : "—").lineLimit(1)
            HStack(spacing: 8) {
                if c.isRunning {
                    DevIconButton(symbol: "arrow.clockwise", help: "Restart (docker restart, after confirmation)", disabled: model.demo) { model.askContainer(.restart, c) }
                    DevIconButton(symbol: "stop.circle", help: "Stop (docker stop, after confirmation)", disabled: model.demo) { model.askContainer(.stop, c) }
                } else {
                    DevIconButton(symbol: "play.circle", help: "Start (docker start, after confirmation)", disabled: model.demo) { model.askContainer(.start, c) }
                }
            }
        }.font(DevUI.font)
    }
}

struct BrewServicesPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: DeveloperModel

    var body: some View {
        Panel(title: "Homebrew services", trailing: "refreshed on open, on Refresh and every 30 s") {
            switch model.brew {
            case nil: ProgressView().controlSize(.small)
            case .noBrew?: Text("Homebrew isn't installed (/opt/homebrew or /usr/local).").font(DevUI.font).foregroundStyle(p.dim)
            case .failed(let r)?: Text("brew services list failed: \(r)").font(DevUI.font).foregroundStyle(.orange).lineLimit(3)
            case .ok(let list)?:
                if list.isEmpty {
                    Text("No formula installed provides a service.").font(DevUI.font).foregroundStyle(p.dim)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow { ForEach(["Service", "Status", "User", "Plist", ""], id: \.self) { Text($0).font(.meterLabel).foregroundStyle(p.dim) } }
                        ForEach(list) { s in row(s) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    func color(_ s: BrewService) -> Color { s.isRunning ? p.accent : s.status == "error" ? .orange : p.dim }

    @ViewBuilder func row(_ s: BrewService) -> some View {
        // A service running as root was started with sudo; `brew services` without sudo can't manage it.
        let rootOwned = s.user == "root"
        GridRow {
            Text(s.name).foregroundStyle(p.text)
            Text(s.status + (s.status == "error" ? s.exitCode.map { " (exit \($0))" } ?? "" : "")).foregroundStyle(color(s))
            Text(s.user ?? "—")
            Text(s.plist.map(DevUI.short) ?? "—").lineLimit(1).truncationMode(.middle).frame(maxWidth: 380, alignment: .leading).textSelection(.enabled)
            HStack(spacing: 8) {
                let off = model.demo || rootOwned
                let why = rootOwned ? " (runs as root: needs sudo brew services in Terminal)" : ""
                if s.isRunning {
                    DevIconButton(symbol: "arrow.clockwise", help: "Restart (after confirmation)" + why, disabled: off) { model.askService(.restart, s) }
                    DevIconButton(symbol: "stop.circle", help: "Stop (after confirmation)" + why, disabled: off) { model.askService(.stop, s) }
                } else {
                    DevIconButton(symbol: "play.circle", help: "Start (after confirmation)" + why, disabled: off) { model.askService(.start, s) }
                }
            }
        }.font(DevUI.font)
    }
}
