// One app's destinations as a table (the Destinations page and the inspector's Network tab share it): name and where
// the name came from, local or internet, services, bytes today / 7 days / 30 days, connections, first and last seen,
// and badges for a new destination and unusual volume.
import SwiftUI
import FlightDeckCore

/// The span the page sorts and filters by. All three byte columns are always shown.
enum DestinationRange: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 days", month = "30 days"
    var id: String { rawValue }
    func bytes(_ d: DestinationSummary) -> UInt64 { switch self { case .today: d.today; case .week: d.week; case .month: d.month } }
    func bytes(_ a: AppDestinations) -> UInt64 { switch self { case .today: a.today; case .week: a.week; case .month: a.month } }
}

struct DestinationTable: View {
    let app: AppDestinations
    var range: DestinationRange = .month
    /// Rows shown before "show all".
    var limit = 25
    @State private var showAll = false
    @Environment(\.palette) var p

    var body: some View {
        let rows = app.destinations.filter { range.bytes($0) > 0 || range == .month }
            .sorted { range.bytes($0) != range.bytes($1) ? range.bytes($0) > range.bytes($1) : $0.id < $1.id }
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text("No traffic in this range.").foregroundStyle(p.dim).font(.caption)
            } else {
                // A Grid isn't lazy, so rows are capped; "show all" lifts the cap for one app.
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["DESTINATION", "NAME FROM", "WHERE", "SERVICE", "TODAY", "7 DAYS", "30 DAYS", "CONN.", "FIRST SEEN", "LAST SEEN"], id: \.self) {
                            Text($0).font(.meterLabel).foregroundStyle(p.dim)
                        }
                    }
                    ForEach(rows.prefix(showAll ? rows.count : limit)) { row($0) }
                }
                .font(.system(size: 11, design: .monospaced))
                if rows.count > limit {
                    Button(showAll ? "Show fewer" : "Show all \(rows.count) destinations") { showAll.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    @ViewBuilder func row(_ d: DestinationSummary) -> some View {
        GridRow {
            HStack(spacing: 5) {
                Text(d.label).fontWeight(d.isNew || d.unusual ? .semibold : .regular).lineLimit(1)
                if d.isNew { DestinationBadge(text: "NEW", color: p.accent).help("First contacted by this app in the last 24 hours, and not in the 30 days before.") }
                if d.unusual {
                    DestinationBadge(text: "UNUSUAL", color: p.warn)
                        .help("\(Fmt.bytes(d.today)) today, against a typical \(Fmt.bytes(d.typicalDay)) per day over \(d.priorDays) earlier days.")
                }
            }
            .help(detail(d))
            Text(nameFrom(d)).foregroundStyle(d.nameSource == .reverseDNS ? p.text : p.dim).help(nameHelp(d))
            Text(d.scope.isLocal ? d.scope.label : (d.provider ?? "internet")).foregroundStyle(d.scope.isLocal ? p.accent2 : p.dim).lineLimit(1)
            Text(services(d)).foregroundStyle(p.dim).lineLimit(1)
            bytes(d.today, d.bytesIn.today, d.bytesOut.today)
            bytes(d.week, d.bytesIn.week, d.bytesOut.week)
            bytes(d.month, d.bytesIn.month, d.bytesOut.month)
            Text("\(d.connections)").monospacedDigit()
            Text(Self.when(d.first)).foregroundStyle(p.dim)
            Text(Self.when(d.last)).foregroundStyle(p.dim)
        }
    }

    func bytes(_ total: UInt64, _ i: UInt64, _ o: UInt64) -> some View {
        Text(total == 0 ? "—" : Fmt.bytes(total)).monospacedDigit().foregroundStyle(total == 0 ? p.dim : p.text)
            .help(total == 0 ? "No traffic" : "↓ \(Fmt.bytes(i)) received · ↑ \(Fmt.bytes(o)) sent")
    }

    func nameFrom(_ d: DestinationSummary) -> String {
        if d.isOther { return "—" }
        switch d.nameSource {
        case .reverseDNS: return "reverse DNS"
        case .none: return "no name"
        case .notLookedUp: return d.scope.lookUp ? "not looked up" : "—"
        }
    }

    func nameHelp(_ d: DestinationSummary) -> String {
        switch d.nameSource {
        case .reverseDNS: return "The IP's PTR record, published by whoever runs the IP (often a hosting or CDN provider). It isn't verified and may not be the service the app used."
        case .none: return "The IP has no reverse-DNS name (or the lookup timed out), so it's shown as the address."
        case .notLookedUp: return "Not looked up: reverse DNS is off, the lookup queue was full, or the address is loopback, link-local or multicast."
        }
    }

    func detail(_ d: DestinationSummary) -> String {
        var parts: [String] = []
        if !d.hosts.isEmpty { parts.append("Hosts: " + d.hosts.joined(separator: ", ")) }
        if !d.ips.isEmpty { parts.append("IPs: " + d.ips.joined(separator: ", ") + (d.ipCount > d.ips.count ? " and \(d.ipCount - d.ips.count) more" : "")) }
        if let pr = d.provider { parts.append("The name belongs to \(pr), which owns the IP; the service the app used isn't known.") }
        return parts.joined(separator: "\n")
    }

    func services(_ d: DestinationSummary) -> String {
        let proto = d.protos.first ?? "tcp"
        let out = d.ports.prefix(2).map { ServiceNames.label(port: $0, proto: proto) }
            + d.inbound.prefix(1).map { "in " + ServiceNames.label(port: $0, proto: proto) }
        return out.isEmpty ? (d.protos.joined(separator: "/").uppercased()) : out.joined(separator: ", ")
    }

    /// "14:05" today, "Tue 14:05" this week, "12 Nov" before.
    static func when(_ t: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(t, inSameDayAs: now) { return t.formatted(date: .omitted, time: .shortened) }
        if now.timeIntervalSince(t) < 6 * 86_400 { return t.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return t.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// A small capsule label ("NEW", "UNUSUAL").
struct DestinationBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .foregroundStyle(color).overlay(Capsule().strokeBorder(color.opacity(0.7), lineWidth: 1))
    }
}
