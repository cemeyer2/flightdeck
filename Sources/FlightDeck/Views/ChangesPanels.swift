import SwiftUI
import FlightDeckCore
// What Changed's panels: the notable changes, one panel per day of the timeline, the row for one change (with its
// signer, path, program and why it may matter, and a link to the page that shows the item), and what's tracked.

extension ChangeEvent.Kind {
    var icon: String {
        switch self { case .added: "plus.circle"; case .removed: "minus.circle"; case .modified: "pencil.circle"; case .updated: "arrow.up.circle" }
    }
    func color(_ p: Palette) -> Color {
        switch self { case .added: p.accent; case .removed: p.dim; case .modified: p.text; case .updated: p.accent2 }
    }
}

extension ChangeCategory {
    var icon: String {
        switch self {
        case .macOS: "apple.logo"; case .launchItem: "power"; case .systemExtension: "puzzlepiece.extension"
        case .kernelExtension: "cpu"; case .profile: "person.badge.shield.checkmark"; case .sharing: "person.2.wave.2"
        case .app: "square.grid.2x2"; case .homebrew: "mug"
        }
    }
}

/// Notable changes in the last 30 days, newest first; clicking one searches the timeline for it.
struct NotableChangesPanel: View {
    @Environment(\.palette) var p
    var events: [ChangeEvent]
    var search: (String) -> Void

    var body: some View {
        if !events.isEmpty {
            Panel(title: "Worth a look", trailing: "\(events.count) notable in 30 days · click to find") {
                ForEach(events.prefix(8)) { e in
                    Button { search(e.item.name) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.shield").foregroundStyle(p.warn).frame(width: 14)
                            Text(e.when.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                                .foregroundStyle(p.dim).frame(width: 150, alignment: .leading)
                            Text(e.summary).lineLimit(1)
                            Text(e.reasons.reversed().joined(separator: " · ")).foregroundStyle(p.warn).lineLimit(1)
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).font(.system(size: 11, design: .monospaced))
                }
            }
        }
    }
}

/// One day of the timeline.
struct ChangeDayPanel: View {
    @Environment(\.palette) var p
    var day: Date
    var events: [ChangeEvent]
    var now: Date

    var title: String {
        let cal = Calendar.current
        let d = day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        if cal.isDate(day, inSameDayAs: now) { return "Today · " + d }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(day, inSameDayAs: y) { return "Yesterday · " + d }
        return d
    }

    var body: some View {
        let notable = events.filter(\.notable).count
        Panel(title: title, trailing: "\(events.count) change\(events.count == 1 ? "" : "s")" + (notable > 0 ? " · \(notable) notable" : "")) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(events) { ChangeRow(event: $0) }
            }
        }
    }
}

/// One change: time, kind, summary, then who/what it is and why it may matter.
struct ChangeRow: View {
    @Environment(\.palette) var p
    @EnvironmentObject var e: Engine
    var event: ChangeEvent

    var body: some View {
        let ev = event, i = ev.item
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ev.when.formatted(date: .omitted, time: .shortened)).foregroundStyle(p.dim).frame(width: 64, alignment: .leading)
                    .help(timeHelp)
                Image(systemName: ev.kind.icon).foregroundStyle(ev.kind.color(p)).frame(width: 14)
                Image(systemName: i.category.icon).foregroundStyle(p.dim).frame(width: 16)
                Text(ev.summary).fontWeight(.medium).foregroundStyle(ev.kind == .removed ? p.dim : p.text).lineLimit(1)
                if ev.notable { badge("NOTABLE", p.warn) }
                Spacer()
                if let page = i.category.page {
                    Button("\(page) ›") { e.navigationRequest = page }.buttonStyle(.borderless).foregroundStyle(p.accent)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            ForEach(details, id: \.self) { line in
                Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim).lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 112)
            }
            if !ev.reasons.isEmpty {
                Text(ev.reasons.joined(separator: " · ").capitalizedFirst).font(.system(size: 11))
                    .foregroundStyle(ev.notable ? p.warn : p.dim).padding(.leading, 112)
            }
        }
    }

    var timeHelp: String {
        let d = event.detected.formatted(date: .abbreviated, time: .shortened)
        guard event.estimated != nil else { return "Detected by FlightDeck's check at \(d)" }
        return (event.category == .macOS ? "The boot after the update" : "The file's modification time") + "; FlightDeck's check found it at \(d)"
    }

    /// Who/what it is: kind and program, signer and team, path, bundle id.
    var details: [String] {
        let i = event.item
        var out: [String] = []
        var head: [String] = []
        if let s = i.scope, i.category != .sharing { head.append(s) }
        if let b = i.bundleID { head.append(b) }
        if let s = i.state, i.category == .systemExtension || i.category == .launchItem { head.append(s) }
        if let s = i.signer { head.append(s) } else if let t = i.teamID { head.append("team \(t)") }
        if !head.isEmpty { out.append(head.joined(separator: " · ")) }
        if let prog = i.program, !prog.isEmpty {
            if let old = event.previous?.program, old != prog { out.append("was: \(old)") }
            out.append("runs: \(prog)")
        }
        if let path = i.path, i.category != .homebrew { out.append(path) }
        return out
    }

    func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(c)
            .padding(.horizontal, 5).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 3).stroke(c.opacity(0.6), lineWidth: 1))
    }
}

/// What the latest inventory holds per category, what couldn't be read (with the reason), and the limits.
struct TrackedPanel: View {
    @Environment(\.palette) var p
    var inventory: Inventory?

    var body: some View {
        Panel(title: "What's tracked", trailing: inventory.map { "inventory of \($0.time.formatted(date: .abbreviated, time: .shortened))" }) {
            if let inv = inventory {
                ForEach(ChangeCategory.allCases) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: c.icon).foregroundStyle(p.dim).frame(width: 16)
                        Text(c.title).frame(width: 230, alignment: .leading)
                        if let why = inv.unavailable[c] {
                            Text("unavailable: \(why)").foregroundStyle(p.dim)
                        } else {
                            Text(count(c, inv)).foregroundStyle(p.text)
                        }
                        Spacer()
                    }.font(.system(size: 11, design: .monospaced))
                }
                ForEach(inv.limits, id: \.self) { Text($0).font(.caption).foregroundStyle(p.dim) }
            } else {
                Text("No inventory yet.").foregroundStyle(p.dim)
            }
        }
    }

    func count(_ c: ChangeCategory, _ inv: Inventory) -> String {
        let items = inv.items(c)
        switch c {
        case .macOS: return items.first?.version ?? "—"
        case .sharing: return "\(items.filter { $0.state == "On" }.count) of \(items.count) on"
        case .kernelExtension, .systemExtension: return items.isEmpty ? "none (third-party)" : "\(items.count) third-party"
        case .homebrew:
            let casks = items.filter { $0.scope == "cask" }.count
            return "\(items.count - casks) formulae, \(casks) casks"
        case .profile:
            let profiles = items.filter { $0.key.hasPrefix("profile:") }.count, managed = items.filter { $0.key.hasPrefix("managed:") }.count
            let mdm = items.first { $0.key == "enrollment:MDM enrollment" }?.state.map { " · MDM enrollment: \($0)" } ?? ""
            return "\(profiles) profile\(profiles == 1 ? "" : "s"), \(managed) managed setting\(managed == 1 ? "" : "s")" + mdm
        default: return "\(items.count)"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
