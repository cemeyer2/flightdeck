import Foundation

// FlightDeck's own boot history (boots.json next to the daily log). macOS's sources expire: the unified log keeps days,
// the power log about a week, process start times only last for the current boot. So whatever FlightDeck learns about
// a boot (its shutdown cause, verdict and login timing) is saved here and kept 90 days, which is what the trend chart
// and older timeline rows read. Also remembers which restarts were already announced as findings.

/// What FlightDeck saved about one boot.
public struct BootRecord: Sendable, Hashable, Codable, Identifiable {
    public var id: Date { boot }
    public var boot: Date
    /// The kernel's shutdown cause logged during this boot, once found.
    public var cause: ShutdownCauseEntry?
    /// true once the unified log was asked for this boot's cause (found or not), so it isn't asked again.
    public var causeQueried = false
    /// The verdict last computed for the shutdown before this boot, kept for when its sources have expired.
    public var verdict: ShutdownVerdict?
    public var timing: BootTiming?
    public init(boot: Date) { self.boot = boot }
}

public final class BootStore: @unchecked Sendable {
    public static let retention: TimeInterval = 90 * 86_400
    struct File: Codable { var boots: [BootRecord] = []; var announced: [String] = []; var lastCheck: Date? }

    /// nil = in memory only (tests, demo, headless renders).
    public let url: URL?
    /// Loads the file but never writes it (MCP tools, off-screen renders): changes stay in memory.
    public let readOnly: Bool
    private let lock = NSLock()
    private var file = File()

    public init(dir: URL?, readOnly: Bool = false) {
        url = dir?.appendingPathComponent("boots.json"); self.readOnly = readOnly
        // Dates are stored as seconds since 1970 (readable when inspecting the file); decoding must use the same.
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        if let url, let d = try? Data(contentsOf: url), let f = try? dec.decode(File.self, from: d) { file = f }
    }

    public var records: [BootRecord] { lock.lock(); defer { lock.unlock() }; return file.boots.sorted { $0.boot > $1.boot } }
    public func record(for boot: Date) -> BootRecord? { records.first { abs($0.boot.timeIntervalSince(boot)) < 60 } }
    public var announced: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(file.announced) }
    public var lastCheck: Date? { lock.lock(); defer { lock.unlock() }; return file.lastCheck }

    /// Changes (or creates) the record for `boot`, matched within a minute since wtmp and kern.boottime differ slightly.
    public func update(_ boot: Date, _ change: (inout BootRecord) -> Void) {
        lock.lock()
        if let i = file.boots.firstIndex(where: { abs($0.boot.timeIntervalSince(boot)) < 60 }) { change(&file.boots[i]) }
        else { var r = BootRecord(boot: boot); change(&r); file.boots.append(r) }
        lock.unlock()
    }

    public func markAnnounced(_ keys: Set<String>, checked: Date) {
        lock.lock(); file.announced = Array(Set(file.announced).union(keys)).sorted(); file.lastCheck = checked; lock.unlock()
    }

    /// Drops records older than 90 days and caps the announcement keys, then writes the file atomically.
    public func save(now: Date = Date()) {
        lock.lock()
        file.boots.removeAll { now.timeIntervalSince($0.boot) > Self.retention }
        if file.announced.count > 500 { file.announced = Array(file.announced.suffix(500)) }
        let f = file
        lock.unlock()
        guard let url, !readOnly else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(f) { try? d.write(to: url, options: .atomic) }
    }
}

/// The one-shot findings: an unexpected shutdown or a panic since FlightDeck last checked, announced once and never
/// again on later launches. The keys are persisted in BootStore.
public enum RestartFindings {
    public static let destination = "Restarts & Crashes"
    /// How long a finding stays in the banner during the session that raised it.
    public static let linger: TimeInterval = 12 * 3600

    public static func key(_ e: BootEvent) -> String { "boot:\(Int(e.boot.timeIntervalSince1970))" }
    public static func key(_ p: PanicReport) -> String { "panic:\((p.path as NSString).lastPathComponent)" }

    /// New findings for events after `since` whose keys aren't in `announced`, and the keys to remember. A boot whose
    /// panic was already announced (or the reverse) isn't announced twice. Panic reports that couldn't be tied to a boot
    /// are announced on their own.
    public static func evaluate(events: [BootEvent], panics: [PanicReport], announced: Set<String>, since: Date) -> (findings: [Finding], keys: Set<String>) {
        var out: [Finding] = [], keys = Set<String>()
        var seenPanics = Set<String>()
        for e in events where e.previous.isUnexpected && e.boot > since {
            let k = key(e), pk = e.previous.panic.map(key)
            if let pk { seenPanics.insert(pk) }
            guard !announced.contains(k), pk.map({ !announced.contains($0) }) ?? true else { continue }
            keys.insert(k); if let pk { keys.insert(pk) }
            let v = e.previous
            let title = v.kind == .panic ? "Your Mac restarted after a kernel panic" + (v.panic?.culpritName.map { " (\($0))" } ?? "")
                : "Your Mac shut down unexpectedly: \(v.title.lowercased())"
            out.append(Finding(id: "restart:\(k)", severity: v.kind == .panic ? .warning : .caution,
                               icon: v.kind == .panic ? "exclamationmark.octagon.fill" : "power",
                               title: title, detail: v.detail, since: e.boot, destination: destination))
        }
        for p in panics where !seenPanics.contains(key(p)) && p.time > since && !announced.contains(key(p)) {
            keys.insert(key(p))
            out.append(Finding(id: "restart:\(key(p))", severity: .warning, icon: "exclamationmark.octagon.fill",
                               title: "Your Mac had a kernel panic", detail: p.explanation, since: p.time, destination: destination))
        }
        return (out, keys)
    }
}

/// Holds the session's restart findings for the sampling loop (thread-safe), so they reach the banner, alerts and
/// the Flight Log the same way as other findings, and drop out `linger` after they were raised.
public final class RestartWatch: @unchecked Sendable {
    public static let shared = RestartWatch()
    private let lock = NSLock()
    private var current: [(Finding, Date)] = []
    public func add(_ f: [Finding], at now: Date = Date()) { lock.lock(); current += f.map { ($0, now) }; lock.unlock() }
    public func findings(now: Date = Date()) -> [Finding] {
        lock.lock(); defer { lock.unlock() }
        current.removeAll { now.timeIntervalSince($0.1) > RestartFindings.linger }
        return current.map(\.0)
    }
}
