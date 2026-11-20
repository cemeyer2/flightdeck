// Settings › Network › Fleet: share this Mac (off by default), the pairing code, and which Macs may read it.
import SwiftUI
import FlightDeckCore

struct FleetSettingsSection: View {
    @AppStorage(FleetService.sharingKey) private var sharing = false
    @ObservedObject private var service = FleetService.shared
    @State private var tick = Date()

    var body: some View {
        Section("Fleet") {
            Toggle("Share this Mac with my other Macs", isOn: $sharing).disabled(Demo.isEnabled)
            if sharing && !Demo.isEnabled {
                if let s = service.status { Text(s).font(.caption) }
                pairingRow
                if !service.viewers.isEmpty {
                    ForEach(service.viewers) { v in
                        HStack {
                            Image(systemName: "eye").foregroundStyle(.secondary)
                            Text(v.name)
                            Text("paired \(v.pairedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { service.removeViewer(v.id) }.help("It can no longer read this Mac; pairing again needs a new code.")
                        }
                    }
                }
            }
            Text(Demo.isEnabled ? "Not available in demo mode."
                 : "Off by default. When on, this Mac announces FlightDeck on the local network (Bonjour) and answers only Macs you pair with a code shown here. Paired Macs can read its vital signs (CPU, memory pressure, temperature, disk free, battery, uptime, thermal state), its findings and incidents (with paths, addresses and names removed; camera, microphone and destination alerts never leave this Mac) and a 30-minute history. Nothing else: no processes, files, user names or network destinations, and they can't change anything. Replies are encrypted for the paired Mac. Other Macs see only this Mac's name.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: sharing) { service.apply() }
        .onAppear { service.refresh() }
    }

    @ViewBuilder var pairingRow: some View {
        let st = service.pairing
        if let locked = st.lockedFor {
            Text("Too many wrong codes. Pairing is paused for \(Int(locked / 60) + 1) min.").font(.caption).foregroundStyle(.orange)
                .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(15)); service.refresh() } }
        } else if let code = st.code, let until = st.openUntil {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pairing code").font(.caption)
                    Text("\(code.prefix(3)) \(code.suffix(3))").font(.system(size: 26, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Text("Enter it on the other Mac's Fleet page. Open for \(max(0, Int(until.timeIntervalSince(tick)))) s; a wrong attempt changes it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { service.closePairing() }
            }
            // While the code shows, re-read it every second: a failed attempt replaces it, and the window times out.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    tick = Date(); service.refresh()
                }
            }
        } else {
            HStack {
                Text("Let another Mac read this one").font(.caption)
                Spacer()
                Button("Pair a Mac…") { service.openPairing(); tick = Date() }
            }
        }
    }
}
