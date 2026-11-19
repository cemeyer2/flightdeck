import Foundation
// Destinations, part 7: what the page, the inspector panel and the MCP tool show. Folds the per-day, per-IP rows into
// apps → destinations (grouped by registrable domain, or IP when unnamed) with bytes today, over 7 and over 30 days,
// and flags new destinations and unusual volume. Pure; built on demand from the stored days and the open one.

/// One destination of one app over the report's days.
public struct DestinationSummary: Sendable, Identifiable, Hashable {
    /// The grouping key: registrable domain, full local name, the IP, or `DestinationRow.otherIP`.
    public var id: String
    public var scope: AddressScope
    /// Distinct host names (at most 5) and IPs (at most 5) seen under it, and how many IPs in all.
    public var hosts: [String] = []
    public var ips: [String] = []
    public var ipCount = 0
    /// "reverse DNS" when any of its IPs had a PTR name; otherwise how the unnamed IP stands.
    public var nameSource: NameSource
    /// Hosting/CDN provider when the reverse name is a provider's (see DomainName.provider).
    public var provider: String?
    public var ports: [UInt16] = [], inbound: [UInt16] = [], protos: [String] = []
    public var bytesIn: (today: UInt64, week: UInt64, month: UInt64) = (0, 0, 0)
    public var bytesOut: (today: UInt64, week: UInt64, month: UInt64) = (0, 0, 0)
    public var connections = 0
    public var first: Date, last: Date
    /// First contacted by this app within the last 24 h (and the app was already known for a day before that).
    public var isNew = false
    /// Today's bytes are at least `Thresholds.unusualFactor` × its average day, over a meaningful amount.
    public var unusual = false
    /// Average bytes per day over the earlier days it appeared on (excluding today), and how many such days.
    public var typicalDay: UInt64 = 0, priorDays = 0

    public var today: UInt64 { bytesIn.today + bytesOut.today }
    public var week: UInt64 { bytesIn.week + bytesOut.week }
    public var month: UInt64 { bytesIn.month + bytesOut.month }
    public var isOther: Bool { id == DestinationRow.otherIP }
    /// What to call it: the grouping key, or a phrase for the overflow row.
    public var label: String { isOther ? "other destinations (over the per-app limit)" : id }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.month == b.month && a.last == b.last && a.isNew == b.isNew }
    public func hash(into h: inout Hasher) { h.combine(id); h.combine(month) }

    /// Case-insensitive match against the name, host names and IPs.
    public func matches(_ q: String) -> Bool {
        id.localizedCaseInsensitiveContains(q) || hosts.contains { $0.localizedCaseInsensitiveContains(q) }
            || ips.contains { $0.localizedCaseInsensitiveContains(q) } || (provider?.localizedCaseInsensitiveContains(q) ?? false)
    }
}

/// One app and the destinations it contacted.
public struct AppDestinations: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Busiest first (30-day bytes).
    public var destinations: [DestinationSummary]
    public var today: UInt64 { destinations.reduce(0) { $0 + $1.today } }
    public var week: UInt64 { destinations.reduce(0) { $0 + $1.week } }
    public var month: UInt64 { destinations.reduce(0) { $0 + $1.month } }
    public var newCount: Int { destinations.filter(\.isNew).count }
    public var unusualCount: Int { destinations.filter(\.unusual).count }
}

public enum DestinationReport {
    public struct Thresholds: Sendable {
        /// Today must reach this many times the destination's typical day…
        public var unusualFactor = 5.0
        /// …and at least this many bytes, so a few KB more than usual never counts…
        public var unusualMinBytes: UInt64 = 50_000_000
        /// …and it needs this many earlier days to compare against.
        public var unusualMinDays = 3
        public init() {}
    }

    /// Builds the report. `days` are stored days plus the open one (any order, at most one per date); only the 30
    /// days ending today are used. Apps sorted by 30-day bytes, busiest first.
    public static func build(days: [DestinationDay], known: KnownDestinations, now: Date, calendar: Calendar = .current,
                             thresholds: Thresholds = Thresholds()) -> [AppDestinations] {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today)!
        let monthStart = calendar.date(byAdding: .day, value: -(DestinationStore.retentionDays - 1), to: today)!
        struct Acc { var s: DestinationSummary; var ipSet: Set<String> = []; var prior: [Date: UInt64] = [:] }
        var apps: [String: (name: String, dests: [String: Acc])] = [:]
        for d in days where d.start >= monthStart && d.start <= today {
            let isToday = d.start == today, inWeek = d.start >= weekStart
            for r in d.rows {
                let key = r.isOther ? DestinationRow.otherIP : r.destinationKey
                var app = apps[r.app] ?? (r.appName, [:])
                var a = app.dests[key] ?? Acc(s: DestinationSummary(id: key, scope: r.scope, nameSource: r.nameSource, first: r.first, last: r.last))
                let s = a.s
                a.s.first = min(s.first, r.first); a.s.last = max(s.last, r.last)
                a.s.connections += r.connections
                a.s.bytesIn.month += r.bytesIn; a.s.bytesOut.month += r.bytesOut
                if inWeek { a.s.bytesIn.week += r.bytesIn; a.s.bytesOut.week += r.bytesOut }
                if isToday { a.s.bytesIn.today += r.bytesIn; a.s.bytesOut.today += r.bytesOut }
                else { a.prior[d.start, default: 0] += r.total }
                if let h = r.host, a.s.hosts.count < 5, !a.s.hosts.contains(h) { a.s.hosts.append(h) }
                if r.nameSource == .reverseDNS || s.nameSource == .reverseDNS { a.s.nameSource = .reverseDNS }
                else if r.nameSource == .none { a.s.nameSource = .none }
                if !r.isOther { a.ipSet.insert(r.ip); if a.s.ips.count < 5, !a.s.ips.contains(r.ip) { a.s.ips.append(r.ip) } }
                for p in r.ports where !a.s.ports.contains(p) && a.s.ports.count < 6 { a.s.ports.append(p) }
                for p in r.inbound where !a.s.inbound.contains(p) && a.s.inbound.count < 6 { a.s.inbound.append(p) }
                for p in r.protos where !a.s.protos.contains(p) { a.s.protos.append(p) }
                app.dests[key] = a
                app.name = r.appName
                apps[r.app] = app
            }
        }
        return apps.map { id, app in
            let dests = app.dests.values.map { a -> DestinationSummary in
                var s = a.s
                s.ipCount = a.ipSet.count
                s.provider = s.hosts.lazy.compactMap(DomainName.provider).first
                s.priorDays = a.prior.count
                s.typicalDay = a.prior.isEmpty ? 0 : a.prior.values.reduce(0, +) / UInt64(a.prior.count)
                s.unusual = s.priorDays >= thresholds.unusualMinDays && s.today >= thresholds.unusualMinBytes
                    && Double(s.today) >= thresholds.unusualFactor * Double(max(s.typicalDay, 1))
                s.isNew = !s.isOther && known.isNew(app: id, dest: s.id, now: now)
                return s
            }.sorted { $0.month != $1.month ? $0.month > $1.month : $0.id < $1.id }
            return AppDestinations(id: id, name: app.name, destinations: dests)
        }.sorted { $0.month != $1.month ? $0.month > $1.month : $0.name < $1.name }
    }

    /// Apps that talked to a destination matching `query` (name, host, IP or provider), each with only the matching
    /// destinations. An empty query returns `apps` unchanged.
    public static func search(_ apps: [AppDestinations], _ query: String) -> [AppDestinations] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        return apps.compactMap { a in
            if a.name.localizedCaseInsensitiveContains(q) { return a }
            let m = a.destinations.filter { $0.matches(q) }
            return m.isEmpty ? nil : AppDestinations(id: a.id, name: a.name, destinations: m)
        }
    }
}
