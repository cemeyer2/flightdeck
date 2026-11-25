import Foundation
// Output of the read-only `system_changes` MCP tool: the changes the FlightDeck app recorded on its What Changed page
// (launch agents and daemons, system and kernel extensions, profiles, sharing services, apps, Homebrew, macOS). The
// tool reads FlightDeck's saved log and never takes an inventory itself, so it reports when the last check ran.

extension MCPTools {
    func systemChanges(_ a: Args) async throws -> JSON {
        let days = try a.int("days", default: 7, 1...90)
        let since = try a.string("since").map { s -> Date in
            guard let d = Self.parseTime(s) else { throw ArgError(message: "since must be an ISO 8601 time, e.g. 2026-11-18T09:00:00Z") }
            return d
        }
        let kinds = try a.choices("kind", ChangeCategory.allCases.map(\.slug))
        let notable = try a.bool("notable_only")
        let limit = try a.int("limit", default: 100, 1...500)
        let report = await Task.detached(priority: .utility) { ChangeStore(dir: ChangeStore.defaultDirectory, readOnly: true).report }.value
        let from = since ?? now().addingTimeInterval(-Double(days) * 86_400)
        let json = Self.systemChangesJSON(report, since: from, kinds: Set(kinds.compactMap { k in ChangeCategory.allCases.first { $0.slug == k } }),
                                          notableOnly: notable, limit: limit, now: now())
        return withHelper(json, await source.helperAccess())
    }

    static func parseTime(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }

    static func changeJSON(_ e: ChangeEvent) -> JSON {
        let i = e.item
        return .object(dropping: [
            ("when", F.time(e.when)), ("when_is", .str(e.estimated == nil ? "detected by FlightDeck's check" : (i.category == .macOS ? "boot after the update" : "file modification time"))),
            ("detected", e.estimated == nil ? nil : F.time(e.detected)),
            ("kind", .str(i.category.slug)), ("change", .str(e.kind.rawValue)), ("summary", .str(e.summary)),
            ("name", .str(i.name)), ("version", i.version.map(JSON.str)), ("previous_version", e.previous?.version.flatMap { $0 == i.version ? nil : .str($0) }),
            ("type", i.scope.map(JSON.str)), ("path", i.path.map(JSON.str)), ("program", i.program.map(JSON.str)),
            ("previous_program", e.previous?.program.flatMap { $0 == i.program ? nil : .str($0) }),
            ("state", i.state.map(JSON.str)), ("bundle_id", i.bundleID.map(JSON.str)),
            ("signer", i.signer.map(JSON.str)), ("team_id", i.teamID.map(JSON.str)), ("signature", i.signature.map { .str($0.rawValue) }),
            ("why_it_may_matter", e.reasons.isEmpty ? nil : .strings(e.reasons)), ("notable", e.notable ? .bool(true) : nil),
        ])
    }

    static func systemChangesJSON(_ r: ChangesReport, since: Date, kinds: Set<ChangeCategory>, notableOnly: Bool, limit: Int, now: Date) -> JSON {
        guard let baseline = r.baseline else {
            return .object([("summary", .str("No inventory has been taken yet: FlightDeck records changes while the app runs (every 15 minutes and when What Changed is opened). Open the FlightDeck app to start.")),
                            ("changes", .array([]))])
        }
        let list = r.filtered(categories: kinds, notableOnly: notableOnly, since: since)
        let notableCount = list.filter(\.notable).count
        var summary = "\(list.count) change\(list.count == 1 ? "" : "s") since \(since.formatted(date: .abbreviated, time: .shortened))"
        summary += notableOnly ? "." : (notableCount > 0 ? ", \(notableCount) notable." : ", none notable.")
        if since < baseline { summary += " FlightDeck's first inventory was taken \(baseline.formatted(date: .abbreviated, time: .shortened)); nothing earlier is known." }
        let byKind = Dictionary(grouping: list, by: \.category).sorted { $0.key < $1.key }
        let inv = r.inventory
        return .object(dropping: [
            ("summary", .str(summary)),
            ("baseline_taken", F.time(baseline)), ("last_check", r.lastCheck.map(F.time)),
            ("last_check_age", r.lastCheck.map { F.duration(now.timeIntervalSince($0)) }),
            ("counts_by_kind", .object(byKind.map { ($0.key.slug, .int($0.value.count)) })),
            ("changes", .array(list.prefix(limit).map(changeJSON))),
            ("truncated", list.count > limit ? .str("\(list.count - limit) older changes not shown; raise limit or narrow the window") : nil),
            ("unavailable", inv.flatMap { i in i.unavailable.isEmpty ? nil : .object(i.unavailable.sorted { $0.key < $1.key }.map { ($0.key.slug, .str($0.value)) }) }),
            ("limits", inv.map { .strings($0.limits) }),
        ])
    }
}
