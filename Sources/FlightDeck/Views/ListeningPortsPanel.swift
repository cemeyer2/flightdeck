import SwiftUI
import FlightDeckCore

// The "Listening ports" panel at the top of Connections: which processes accept connections on which ports, and
// whether they're reachable from the network. Scanned when shown and on Refresh only (no timer: listeners change
// rarely, and the sockets table below already polls).

struct ListeningPortsPanel: View {
    @Environment(\.palette) var p
    @StateObject var loader = Loader { ListeningPorts.scan() }
    @AppStorage("listeningPortsExpanded") private var expanded = true

    var body: some View {
        if Demo.isEnabled {
            Text("Listening ports: not available in demo mode.").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim).padding(10)
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                content.padding(.top, 4)
            } label: {
                HStack {
                    Text("LISTENING PORTS").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(p.dim)
                    if let s = loader.value {
                        let open = s.sockets.filter { $0.exposure == .allInterfaces }.count
                        Text("\(s.sockets.count) sockets · \(open) on all interfaces").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(open > 0 ? .orange : p.dim)
                    }
                    Spacer()
                    if loader.loading { ProgressView().controlSize(.small) }
                    Button("Refresh") { loader.load() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .onAppear { loader.load() }
        }
    }

    @ViewBuilder var content: some View {
        if let s = loader.value {
            // No `fixedSize(vertical:)`: inside the DisclosureGroup that let a near-zero width measurement report a huge
            // minimum height, which pushed the whole window's content (sidebar included) off screen.
            Text(coverageText(s.coverage)).font(.system(size: 11)).foregroundStyle(p.dim).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            // A fixed-height scrolling grid so the sockets table below keeps most of the window.
            MaybeScroll {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { ForEach(["Process", "PID", "Proto", "Address", "Port", "Reachable from"], id: \.self) { Text($0).font(.meterLabel).foregroundStyle(p.dim) } }
                    ForEach(s.sockets) { l in
                        GridRow {
                            Text(l.process).lineLimit(1)
                            Text(verbatim: "\(l.pid)").monospacedDigit()
                            Text("\(l.proto) \(l.family)")
                            Text(l.address).textSelection(.enabled)
                            Text(verbatim: "\(l.port)").monospacedDigit()
                            Label(l.exposure == .allInterfaces ? "network (all interfaces)" : l.exposure == .loopback ? "this Mac only" : "one interface",
                                  systemImage: l.exposure == .allInterfaces ? "exclamationmark.triangle.fill" : (l.exposure == .loopback ? "lock" : "network"))
                                .foregroundStyle(l.exposure == .allInterfaces ? .orange : p.dim)
                        }.font(.system(size: 11, design: .monospaced))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            // An explicit height (rows × ~19 pt, capped at 220) rather than `maxHeight`: a ScrollView with only a maximum
            // inside a DisclosureGroup above the sockets Table made the page's VStack overflow the window when expanded.
            .frame(height: min(CGFloat(s.sockets.count + 1) * 19 + 8, 220))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    func coverageText(_ c: ListeningScan.Coverage) -> String {
        switch c {
        case .allProcesses:
            "Every process's listening sockets, from netstat. \"All interfaces\" means other devices on the network can connect unless the firewall blocks them."
        case .ownProcessesOnly(let why):
            "Your own processes only: \(why), so this list comes from lsof, which can't see other users' or system services' sockets without root."
        case .failed(let why):
            "Couldn't list listening ports: \(why)."
        }
    }
}
