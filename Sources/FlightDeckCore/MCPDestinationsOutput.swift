import Foundation
// Output of the read-only `network_destinations` MCP tool: which hosts each app exchanged traffic with over the last
// N days, busiest first, with bytes, connections, first and last seen, ports, and new/unusual flags. Every name says
// where it came from ("reverse DNS" or "no name"), so a model never presents a PTR record as the service an app used.

extension MCPTools {
    func networkDestinations(_ a: Args) async throws -> JSON {
        let days = try a.int("days", default: 7, 1...DestinationStore.retentionDays)
        let limit = try a.int("limit", default: 20, 1...200)
        let appQuery = try a.string("app")
        let hostQuery = try a.string("destination")
        guard let src = await source.destinations() else {
            return object([("summary", F.unavailable("destinations are recorded by the FlightDeck app"))])
        }
        let now = self.now()
        let cal = Calendar.current
        let windowStart = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: now))!
        // Flags (new, unusual) need the full 30 days; byte totals come from the requested window only.
        let full = DestinationReport.build(days: src.days, known: src.known, now: now)
        let windowed = DestinationReport.build(days: src.days.filter { $0.start >= windowStart }, known: src.known, now: now)
        let flags = Dictionary(full.flatMap { a in a.destinations.map { ("\(a.id)|\($0.id)", $0) } }, uniquingKeysWith: { a, _ in a })
        var apps = windowed
        if let q = appQuery {
            apps = apps.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q) }
        }
        if let h = hostQuery { apps = DestinationReport.search(apps, h).filter { a in a.destinations.contains { $0.matches(h) } } }

        func destJSON(_ app: AppDestinations, _ d: DestinationSummary) -> JSON {
            let f = flags["\(app.id)|\(d.id)"]
            let services = (d.ports.map { ServiceNames.label(port: $0, proto: d.protos.first ?? "tcp") }
                            + d.inbound.map { "inbound " + ServiceNames.label(port: $0, proto: d.protos.first ?? "tcp") })
            return .object(dropping: [
                ("destination", .str(d.label)), ("name_source", .str(d.nameSource.rawValue)),
                ("hosts", d.hosts.isEmpty ? nil : .strings(d.hosts)), ("ips", d.ips.isEmpty ? nil : .strings(d.ips)),
                ("ip_count", d.ipCount > d.ips.count ? .int(d.ipCount) : nil),
                ("scope", .str(d.scope.label)), ("hosting_provider", d.provider.map(JSON.str)),
                ("services", services.isEmpty ? nil : .strings(services)), ("protocols", .strings(d.protos)),
                ("bytes_in", F.bytes(Double(d.bytesIn.month))), ("bytes_out", F.bytes(Double(d.bytesOut.month))),
                ("today", days > 1 ? F.bytes(Double(d.today)) : nil),
                ("connections", .int(d.connections)), ("first_seen", F.time(d.first)), ("last_seen", F.time(d.last)),
                ("new_for_this_app", f?.isNew == true ? .bool(true) : nil),
                ("unusual_volume", f?.unusual == true ? .str("\(Fmt.bytes(f!.today)) today vs. a typical \(Fmt.bytes(f!.typicalDay)) per day") : nil),
            ])
        }
        let shownApps = apps.prefix(limit)
        let appJSON: [JSON] = shownApps.map { app in
            let dests = app.destinations.prefix(limit)
            return .object(dropping: [
                ("app", .str(app.name)), ("id", .str(app.id)),
                ("bytes", F.bytes(Double(app.month))), ("destination_count", .int(app.destinations.count)),
                ("destinations", .array(dests.map { destJSON(app, $0) })),
                ("destinations_omitted", app.destinations.count > limit ? .int(app.destinations.count - limit) : nil),
            ])
        }
        let newCount = full.reduce(0) { $0 + $1.newCount }
        let counted = src.days.filter { $0.start >= windowStart && $0.firstCounted != nil }.count
        let summary = apps.isEmpty
            ? "No destinations recorded in the last \(days) day\(days == 1 ? "" : "s")" + (appQuery.map { " for an app matching '\($0)'" } ?? "") + "."
            : "\(apps.count) app\(apps.count == 1 ? "" : "s") contacted \(apps.reduce(0) { $0 + $1.destinations.count }) destinations in the last \(days) day\(days == 1 ? "" : "s") (\(counted) of them recorded). \(newCount) new destination\(newCount == 1 ? "" : "s") in the last 24 h."
        return object([
            ("summary", .str(summary)),
            ("apps", .array(appJSON)),
            ("apps_omitted", apps.count > limit ? .int(apps.count - limit) : nil),
            ("note", .str("Traffic is per connection as macOS's nettop reports it, sampled every 1-5 s while FlightDeck runs: connections that open and close between samples, and bytes after the last sample before a connection closes, are missed. Destinations are grouped by the registrable domain of the IP's reverse-DNS (PTR) name, which the IP's owner publishes (often a hosting or CDN provider) and which isn't verified; name_source 'no name' means there was no PTR record, 'not looked up' that none was attempted. Apps don't reveal which host name they resolved. new_for_this_app = first contact in the last 24 h, not contacted in the previous 30 days. Recorded on this Mac only.")),
        ])
    }
}
