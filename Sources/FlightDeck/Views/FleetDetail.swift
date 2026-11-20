// Fleet: the read-only detail panel for one paired Mac. Every value it shows came from that Mac's FleetStatus;
// anything it couldn't measure is shown as "—" with the reason in its tooltip.
import SwiftUI
import FlightDeckCore

struct FleetDetail: View {
    @Environment(\.palette) var p
    var host: FleetHostState
    var forget: () -> Void
    @State private var confirmForget = false

    var body: some View {
        let s = host.status
        VStack(alignment: .leading, spacing: 12) {
            Panel(title: host.name, trailing: trailing) {
                identity(s?.identity)
                if let v = s?.vitals, host.online == true { vitals(v) }
                else if host.online == true, let r = s?.vitalsReason { Text(r).font(.system(size: 12)).foregroundStyle(p.dim) }
                else { Text("Offline. Showing the last answer it gave, if any.").font(.system(size: 12)).foregroundStyle(p.dim) }
            }
            if let s, !s.history.isEmpty { history(s) }
            HStack(alignment: .top, spacing: 12) {
                list("Current findings", s?.findings ?? [], empty: host.online == true ? "Nothing wrong right now." : "Unknown while offline.")
                    .frame(maxWidth: .infinity)
                list("Recent incidents", s?.incidents ?? [], empty: "No incidents recorded.").frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog("Forget \(host.name)?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive, action: forget)
        } message: { Text("This Mac stops reading it. To see it again you'll need a new code from that Mac.") }
    }

    var trailing: String {
        switch host.online {
        case true?: return host.status.map { "updated \(FleetFormat.ago($0.vitals?.sampledAt ?? Date()))" } ?? "online"
        case false?: return host.peer.lastSeen.map { "offline · last seen \(FleetFormat.ago($0))" } ?? "offline"
        case nil: return "checking…"
        }
    }

    func identity(_ id: FleetIdentity?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: FleetIdentity.icon(id?.kind ?? host.peer.kind)).font(.system(size: 34)).foregroundStyle(p.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text([id?.model ?? host.peer.model, id.map { "macOS \($0.macOS)" }, id.map { "FlightDeck \($0.appVersion)" }]
                    .compactMap { $0 }.joined(separator: " · ")).font(.system(size: 12))
                Text("Paired \(host.peer.pairedAt.formatted(date: .abbreviated, time: .omitted)) · read-only")
                    .font(.system(size: 11)).foregroundStyle(p.dim)
            }
            Spacer()
            Button("Forget…") { confirmForget = true }
        }
    }

    func value(_ v: FleetValue, _ f: (Double) -> String) -> String? { v.value.map(f) }

    func vitals(_ v: FleetVitals) -> some View {
        let level = v.memoryLevel ?? 1
        let memColor: Color? = level >= 4 ? p.crit : (level >= 2 ? p.warn : nil)
        let thermal = FleetFormat.thermal[min(max(v.thermalState, 0), 3)]
        let disk = v.diskFree.value.map { free in v.diskTotal.value.map { "\(Fmt.storage(free)) of \(Fmt.storage($0))" } ?? Fmt.storage(free) }
        let mem = v.memoryUsed.value.map { used in v.memoryTotal.value.map { "\(Fmt.bytes(used)) / \(Fmt.bytes($0))" } ?? Fmt.bytes(used) }
        let battery = v.battery.map { "\(Int($0.percent.rounded()))%" + ($0.charging ? " ⚡︎" : ($0.onPower ? " (on power)" : "")) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 26) {
                Readout(label: "CPU", value: value(v.cpu) { String(format: "%.0f", $0) }, unit: "%", size: 18).help(v.cpu.reason ?? "")
                Readout(label: "Memory pressure", value: value(v.memoryPressure) { String(format: "%.0f", $0) }, unit: "%", color: memColor, size: 18)
                    .help(v.memoryPressure.reason ?? "")
                Readout(label: "Hottest", value: v.hottest.value.map { Fmt.tempNumber($0) }, unit: TemperatureUnit.current.symbol, size: 18)
                    .help(v.hottest.reason ?? "")
                Readout(label: "Thermal state", value: thermal, color: v.thermalState >= 2 ? p.warn : nil, size: 18)
                Spacer()
            }
            HStack(spacing: 26) {
                Readout(label: "Memory used", value: mem, size: 14).help(v.memoryUsed.reason ?? "")
                Readout(label: "Startup disk free", value: disk, size: 14).help(v.diskFree.reason ?? "")
                Readout(label: "Battery", value: battery, size: 14).help(v.batteryReason ?? "")
                Readout(label: "Uptime", value: v.uptime.value.map(FleetFormat.uptime), size: 14).help(v.uptime.reason ?? "")
                Spacer()
            }
            if v.battery == nil, let r = v.batteryReason { Text("Battery: \(r.lowercased()).").font(.system(size: 11)).foregroundStyle(p.dim) }
        }
    }

    func history(_ s: FleetStatus) -> some View {
        let h = s.history
        let span = h.first.map { Int((h.last!.t.timeIntervalSince($0.t) / 60).rounded()) } ?? 0
        return Panel(title: "Last \(max(span, 1)) minutes", trailing: "one point every \(Int(FleetService.historyStep)) s") {
            FleetSparkRow(label: "CPU", values: h.map(\.cpu), latest: h.last?.cpu.map { "\(Int($0.rounded()))%" }, color: p.accent, height: 34)
            FleetSparkRow(label: "MEM", values: h.map(\.memoryPressure), latest: h.last?.memoryPressure.map { "\(Int($0.rounded()))%" }, color: p.accent2, height: 34)
            FleetSparkRow(label: "TEMP", values: h.map(\.hottest), latest: h.last?.hottest.map { Fmt.temp($0) }, color: p.warn, ceiling: nil, height: 34)
        }
    }

    func list(_ title: String, _ items: [FleetFinding], empty: String) -> some View {
        Panel(title: title, trailing: items.isEmpty ? nil : "\(items.count)") {
            if items.isEmpty { Text(empty).font(.system(size: 12)).foregroundStyle(p.dim) }
            ForEach(items) { f in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: f.icon).foregroundStyle(FleetFormat.severityColor(f.severity, p)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.title).font(.system(size: 12))
                        if let d = f.detail { Text(d).font(.system(size: 11)).foregroundStyle(p.dim) }
                        Text(when(f)).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    func when(_ f: FleetFinding) -> String {
        let start = f.since.formatted(date: .abbreviated, time: .shortened)
        guard let end = f.end else { return "since \(start)" + (f.since < Date().addingTimeInterval(-60) ? " (\(FleetFormat.ago(f.since)))" : "") }
        return "\(start) · lasted \(Fmt.duration(end.timeIntervalSince(f.since)))"
    }
}
