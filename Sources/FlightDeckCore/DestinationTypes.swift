import Foundation
// Destinations, part 3: the records. One `DestinationRow` per (app, remote IP) per day, holding what nettop showed
// the app's connections to that IP moving; `DestinationDay` is a day of them, persisted as one JSON file. Names come
// later and asynchronously (reverse DNS), so a row carries its name and where the name came from.

/// Where a destination's name came from. Never inferred: an IP without a PTR record stays "no name".
public enum NameSource: String, Codable, Sendable {
    /// From a PTR record for the IP. Set by whoever controls the IP's reverse zone (usually the hosting provider) and
    /// not verified against forward DNS, so it names the machine's owner, not necessarily the service the app used.
    case reverseDNS = "reverse DNS"
    /// Looked up, and there was no PTR record (or the lookup timed out).
    case none = "no name"
    /// Not looked up: lookups are off, the address is loopback/link-local/multicast, or the lookup is still queued.
    case notLookedUp = "not looked up"
}

/// One app's traffic to one remote IP on one day.
public struct DestinationRow: Codable, Sendable, Hashable {
    /// `AppUsage` grouping key (bundle path or "proc:<name>") and display name.
    public var app: String
    public var appName: String
    /// The remote address, or `DestinationRow.otherIP` for the overflow row of an app with too many destinations.
    public var ip: String
    public var scope: AddressScope
    public var host: String?
    public var nameSource: NameSource
    /// Service ports seen (distinct, at most `maxPorts`); `inbound` marks ports that were this Mac's (a server here).
    public var ports: [UInt16] = []
    public var inbound: [UInt16] = []
    /// Transport protocols seen ("tcp", "udp", "quic").
    public var protos: [String] = []
    public var bytesIn: UInt64 = 0
    public var bytesOut: UInt64 = 0
    /// Connections (distinct nettop flows) seen opening, or already open when FlightDeck began watching.
    public var connections = 0
    /// First and last time a connection to this IP opened or moved bytes, this day.
    public var first: Date
    public var last: Date

    public static let otherIP = "*"
    static let maxPorts = 6
    public var total: UInt64 { bytesIn + bytesOut }
    public var isOther: Bool { ip == Self.otherIP }

    public init(app: String, appName: String, ip: String, scope: AddressScope, host: String? = nil,
                nameSource: NameSource = .notLookedUp, first: Date, last: Date) {
        self.app = app; self.appName = appName; self.ip = ip; self.scope = scope; self.host = host
        self.nameSource = nameSource; self.first = first; self.last = last
    }

    /// How this row's destination is grouped: an internet host by the registrable domain of its name, else by the IP.
    /// A local one by its full name: LAN names share made-up suffixes ("printer.home.arpa", "nas.lan"), so grouping
    /// them by domain would merge unrelated devices.
    public var destinationKey: String { Self.key(host: host, ip: ip, scope: scope) }
    public static func key(host: String?, ip: String, scope: AddressScope) -> String {
        guard let h = host.flatMap(DomainName.normalize) else { return ip }
        return scope.isLocal ? h : (DomainName.registrable(h) ?? ip)
    }

    mutating func addPort(_ p: UInt16, inbound isIn: Bool, proto: String) {
        if isIn { if !inbound.contains(p) && inbound.count < Self.maxPorts { inbound.append(p) } }
        else if !ports.contains(p) && ports.count < Self.maxPorts { ports.append(p) }
        if !protos.contains(proto) && protos.count < 4 { protos.append(proto) }
    }

    /// Folds another row for the same destination in (same day, or across days for reports).
    mutating func merge(_ o: DestinationRow) {
        bytesIn += o.bytesIn; bytesOut += o.bytesOut; connections += o.connections
        first = min(first, o.first); last = max(last, o.last)
        for p in o.ports { addPort(p, inbound: false, proto: o.protos.first ?? "tcp") }
        for p in o.inbound { addPort(p, inbound: true, proto: o.protos.first ?? "tcp") }
        for p in o.protos where !protos.contains(p) { protos.append(p) }
        if host == nil, o.host != nil { host = o.host; nameSource = o.nameSource }
    }
}

/// One day of destination rows. Days FlightDeck didn't run have no file at all (not measured, not zero).
public struct DestinationDay: Codable, Sendable {
    /// Local midnight starting the day.
    public var start: Date
    public var rows: [DestinationRow]
    /// When counting started and last happened this day.
    public var firstCounted: Date?
    public var lastCounted: Date?
    /// Rows folded into an app's "other destinations" row because it reached `DestinationTracker.Config.maxPerApp`.
    public var overflowed = 0
    public init(start: Date, rows: [DestinationRow] = [], firstCounted: Date? = nil, lastCounted: Date? = nil) {
        self.start = start; self.rows = rows; self.firstCounted = firstCounted; self.lastCounted = lastCounted
    }
}

/// Which destinations each app has contacted before, for "new destination" detection. Kept for the retention period
/// (entries not seen for longer are pruned), so "new" means "not in the last 30 days".
public struct KnownDestinations: Codable, Sendable {
    public struct App: Codable, Sendable {
        public var name: String
        /// When FlightDeck first saw this app talk to anything.
        public var first: Date
        /// destination key → (first seen, last seen).
        public var dests: [String: Seen] = [:]
    }
    public struct Seen: Codable, Sendable { public var first: Date; public var last: Date }
    public var apps: [String: App] = [:]
    public init() {}

    /// An app's destination counts as new only after FlightDeck has watched the app for this long, so the first day
    /// with FlightDeck (or with a newly installed app) doesn't flag everything.
    public static let learning: TimeInterval = 86_400
    /// "New" lasts this long after first contact.
    public static let window: TimeInterval = 86_400
    /// Most destinations remembered per app (the least recently seen are dropped first).
    static let maxPerApp = 3000

    /// Records a contact. Returns true when it was the first contact with a destination of an established app.
    @discardableResult
    public mutating func note(app: String, name: String, dest: String, at t: Date) -> Bool {
        var a = apps[app] ?? App(name: name, first: t)
        a.first = min(a.first, t)
        if var s = a.dests[dest] {
            s.first = min(s.first, t); s.last = max(s.last, t); a.dests[dest] = s
            apps[app] = a
            return false
        }
        a.dests[dest] = Seen(first: t, last: t)
        if a.dests.count > Self.maxPerApp, let oldest = a.dests.min(by: { $0.value.last < $1.value.last })?.key { a.dests[oldest] = nil }
        apps[app] = a
        return t.timeIntervalSince(a.first) >= Self.learning
    }

    /// True if `dest` was first contacted by `app` within `window` of `now`, and the app was established by then.
    public func isNew(app: String, dest: String, now: Date) -> Bool {
        guard let a = apps[app], let s = a.dests[dest] else { return false }
        return now.timeIntervalSince(s.first) < Self.window && s.first.timeIntervalSince(a.first) >= Self.learning
    }

    /// Drops destinations last seen before `cutoff`, and apps left with none.
    public mutating func prune(before cutoff: Date) {
        for (k, var a) in apps {
            a.dests = a.dests.filter { $0.value.last >= cutoff }
            apps[k] = a.dests.isEmpty ? nil : a
        }
    }
}
