import SwiftUI
import FlightdeckCore

extension Palette {
    func color(_ s: Finding.Severity) -> Color {
        switch s { case .info: accent; case .caution: warn; case .warning: crit }
    }
}

func shortDuration(_ s: TimeInterval) -> String {
    let m = Int(s / 60)
    if m < 1 { return "\(Int(s)) s" }
    if m < 60 { return "\(m) min" }
    return "\(m / 60) h \(m % 60) min"
}

/// One finding: severity light, title, how long, explanation; clicking jumps to where to look.
struct FindingRow: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var f: Finding
    var compact = false
    var body: some View {
        Button { if let d = f.destination { e.navigationRequest = d } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: f.icon).foregroundStyle(p.color(f.severity)).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(f.title).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(p.text)
                        let d = (e.current?.time ?? Date()).timeIntervalSince(f.since)
                        if d >= 10 { Text("· \(shortDuration(d))").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim) }
                    }
                    if !compact, let detail = f.detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if f.destination != nil { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(p.dim) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct FlightLogView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @State private var confirmClear = false
    @AppStorage("flightLogMinSeverity") private var minSeverity = 1

    var body: some View {
        let shown = e.incidents.filter { $0.severity.rawValue >= minSeverity }.reversed()
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.start) }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Panel(title: "Right now", trailing: e.mode == .replay ? "at the replayed moment" : nil) {
                    if e.findings.isEmpty {
                        Label("All systems normal.", systemImage: "checkmark.seal").foregroundStyle(p.text)
                    }
                    ForEach(e.findings) { FindingRow(f: $0) }
                }
                HStack {
                    Picker("Show", selection: $minSeverity) {
                        Text("Everything").tag(1); Text("Cautions and warnings").tag(2); Text("Warnings only").tag(3)
                    }.frame(width: 300)
                    Spacer()
                    Text("\(e.incidents.count) incident\(e.incidents.count == 1 ? "" : "s") in the last 7 days").font(.caption).foregroundStyle(p.dim)
                    Button("Clear…") { confirmClear = true }.disabled(e.incidents.isEmpty)
                }
                if shown.isEmpty {
                    Text("Nothing logged yet. Anything that lasts 20 seconds or more (a busy app, memory pressure, heat, a filling disk) is logged here, with a replay of what the Mac was doing.")
                        .foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    Panel(title: day.formatted(date: .complete, time: .omitted)) {
                        ForEach(days[day]!) { IncidentRow(i: $0) }
                    }
                }
            }.padding(16)
        }
        .confirmationDialog("Clear the flight log?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { e.clearIncidents() }
        }
    }
}

struct IncidentRow: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var i: Incident
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(i.start.formatted(date: .omitted, time: .shortened)).frame(width: 64, alignment: .leading)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(p.dim)
            Image(systemName: i.icon).foregroundStyle(p.color(i.severity)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(i.title).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(p.text)
                Text((i.end == nil ? "ongoing · " : "") + shortDuration(i.duration) + (i.detail.map { " · " + $0 } ?? ""))
                    .font(.system(size: 11)).foregroundStyle(p.dim).lineLimit(2)
            }
            Spacer()
            if Date().timeIntervalSince(i.end ?? Date()) < 86_400 {
                Button { e.replayBlackBox(from: i.start, to: i.end ?? Date()) } label: { Label("Replay", systemImage: "film") }
                    .help("Replay what the Mac was doing (from the black box)").disabled(!e.blackBoxEnabled)
            }
        }
        .padding(.vertical, 2)
    }
}
