import Foundation

// The boot timeline behind Restarts & Crashes: every boot macOS recorded, and how the session before it ended. No
// single no-root source says that reliably, so several are combined, strongest first:
//   1. a kernel panic report written for that session (certain: the Mac panicked);
//   2. the kernel's "Previous shutdown cause" code from the unified log (the hardware's own record; the log keeps
//      only days, so FlightDeck saves what it finds in its boot history);
//   3. an orderly-shutdown marker: logd writes "SIGTERM: [time] All buffers flushed" to
//      /var/db/diagnostics/shutdown.log when macOS shuts down properly, and wtmp gets a shutdown record;
//   4. otherwise, if the shutdown log reaches back over that session, the absence of a marker means the Mac stopped
//      without shutting down (power loss, a forced shutdown, a freeze or panic without a report). This is an
//      inference and is labelled as one.

/// A power event from `pmset -g log` that isn't sleep or wake: shutdown, restart, start, or a wake from hibernation.
public struct PowerLogEvent: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case shutdown, restart, start, hibernateWake }
    public var time: Date
    public var kind: Kind
    public var message: String
    public init(time: Date, kind: Kind, message: String) { self.time = time; self.kind = kind; self.message = message }
}

/// Everything read from the machine, before classification. Each list may be empty when its source isn't readable.
public struct BootSources: Sendable {
    public var boots: [Date] = []               // wtmp boot records and kern.boottime
    public var shutdownRecords: [Date] = []     // wtmp shutdown records
    public var logins: [Date] = []              // wtmp console logins (any user)
    public var logdFlushes: [Date] = []         // orderly shutdowns from shutdown.log
    public var causes: [ShutdownCauseEntry] = []
    public var panics: [PanicReport] = []
    public var power: [PowerLogEvent] = []
    /// The power log's first entry (it keeps about a week).
    public var powerLogSince: Date?
    public init() {}
}

/// How the session before a boot ended.
public struct ShutdownVerdict: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case clean = "Clean", unexpected = "Unexpected", panic = "Kernel panic", unknown = "Unknown" }
    public var kind: Kind
    public var title: String
    /// Plain-English explanation of what happened and, where useful, what to do.
    public var detail: String
    public var cause: ShutdownCause?
    public var panic: PanicReport?
    /// When the session ended, if a source says (panic time, shutdown marker); nil when only the boot is known.
    public var ended: Date?
    /// The sources that support the verdict, in words ("kernel shutdown cause 5", "orderly-shutdown marker").
    public var evidence: [String]
    /// true when the verdict is inferred from a missing record rather than read from one.
    public var inferred: Bool
    public var isUnexpected: Bool { kind == .unexpected || kind == .panic }
}

public struct BootEvent: Sendable, Hashable, Identifiable {
    public var id: Date { boot }
    public var boot: Date
    public var previousBoot: Date?
    public var previous: ShutdownVerdict
    /// First console login after this boot (wtmp), if any before the next boot.
    public var login: Date?
}

public enum BootHistory {
    /// A message or report written within this long after a boot belongs to that boot's startup.
    static let bootWindow: TimeInterval = 15 * 60

    /// The latest boot at or before `t`.
    static func boot(atOrBefore t: Date, in boots: [Date]) -> Date? { boots.last { $0 <= t } }

    /// The boot whose *previous* shutdown an item at time `t` describes. Something logged or written during a boot's
    /// first minutes (the shutdown cause, a panic report's write time) is about the shutdown before it. A panic's own
    /// time lies inside the session it ended, so it belongs to the next boot after it.
    static func owner(of t: Date, atBoot: Bool, boots: [Date]) -> Date? {
        if atBoot, let b = boot(atOrBefore: t, in: boots), t.timeIntervalSince(b) < bootWindow { return b }
        return boots.first { $0 > t }
    }

    /// Classifies the shutdown before each boot. `boots` may be unsorted and have near-duplicates (wtmp and
    /// kern.boottime differ by under a second); boots closer than a minute are merged. Newest first.
    public static func classify(_ src: BootSources) -> [BootEvent] {
        var boots: [Date] = []
        for b in src.boots.sorted() where boots.last.map({ b.timeIntervalSince($0) > 60 }) ?? true { boots.append(b) }
        guard !boots.isEmpty else { return [] }
        let flushes = src.logdFlushes.sorted()
        // The shutdown log reaches back to its first marker; a session that started after it is covered by it.
        let coverage = flushes.first
        var panicFor: [Date: PanicReport] = [:], causeFor: [Date: ShutdownCauseEntry] = [:]
        for p in src.panics {
            if let b = owner(of: p.time, atBoot: !p.timeIsPanic, boots: boots), panicFor[b] == nil { panicFor[b] = p }
        }
        for c in src.causes.sorted(by: { $0.logged < $1.logged }) {
            if let b = owner(of: c.logged, atBoot: true, boots: boots), causeFor[b] == nil { causeFor[b] = c }
        }
        var out: [BootEvent] = []
        for (i, b) in boots.enumerated() {
            let prev = i > 0 ? boots[i - 1] : nil
            let next = i + 1 < boots.count ? boots[i + 1] : Date.distantFuture
            // Markers strictly between the previous boot and this one (a minute of slack for clock rounding).
            func inSession(_ d: Date) -> Bool { (prev.map { d > $0 } ?? true) && d <= b.addingTimeInterval(60) && d > b.addingTimeInterval(-30 * 86_400) }
            let marker = flushes.last(where: inSession)
            let wtmpShutdown = src.shutdownRecords.last(where: inSession)
            let pm = src.power.last { ($0.kind == .shutdown || $0.kind == .restart) && inSession($0.time) }
            let covered = prev != nil && coverage.map { $0 <= prev! } == true
            let verdict = decide(panic: panicFor[b], cause: causeFor[b], marker: marker ?? wtmpShutdown, markerSource: marker != nil ? "logd's orderly-shutdown marker" : "a shutdown record in wtmp",
                                 power: pm, covered: covered, hasPrevious: prev != nil)
            let login = src.logins.filter { $0 >= b && $0 < next }.min()
            out.append(BootEvent(boot: b, previousBoot: prev, previous: verdict, login: login))
        }
        return out.reversed()
    }

    /// The verdict for one session end, from the evidence found for it. Pure, so the precedence is unit-tested.
    static func decide(panic: PanicReport?, cause: ShutdownCauseEntry?, marker: Date?, markerSource: String,
                       power: PowerLogEvent?, covered: Bool, hasPrevious: Bool) -> ShutdownVerdict {
        var evidence: [String] = []
        let sc = cause.map { ShutdownCause.of($0.code) }
        if let cause { evidence.append("kernel shutdown cause \(cause.code)") }
        if let panic {
            evidence.insert("panic report \((panic.path as NSString).lastPathComponent)", at: 0)
            return ShutdownVerdict(kind: .panic, title: "Kernel panic: \(panic.culprit.rawValue.lowercased())", detail: panic.explanation,
                                   cause: sc, panic: panic, ended: panic.timeIsPanic ? panic.time : nil, evidence: evidence, inferred: false)
        }
        if marker != nil { evidence.append(markerSource) }
        if let power { evidence.append("power log: \(power.message)") }
        if let sc {
            switch sc.concern {
            case .normal:
                return ShutdownVerdict(kind: .clean, title: sc.title, detail: sc.meaning, cause: sc, panic: nil, ended: marker, evidence: evidence, inferred: false)
            case .unknown:
                // An undocumented code with an orderly marker is most likely fine; without one it stays unknown.
                return ShutdownVerdict(kind: marker != nil ? .clean : .unknown, title: sc.title,
                                       detail: sc.meaning + (marker != nil ? " macOS did record an orderly shutdown, so it was probably normal." : ""),
                                       cause: sc, panic: nil, ended: marker, evidence: evidence, inferred: marker != nil)
            case .notable, .concern:
                return ShutdownVerdict(kind: .unexpected, title: sc.title, detail: sc.meaning + (sc.advice.map { " " + $0 } ?? ""),
                                       cause: sc, panic: nil, ended: marker, evidence: evidence, inferred: false)
            }
        }
        if marker != nil || power != nil {
            return ShutdownVerdict(kind: .clean, title: power?.kind == .restart ? "Restarted normally" : "Shut down normally",
                                   detail: "macOS shut down in an orderly way (apps were asked to quit and the logs were saved).",
                                   cause: nil, panic: nil, ended: marker ?? power?.time, evidence: evidence, inferred: false)
        }
        if covered {
            evidence.append("no orderly-shutdown marker in a log that covers this period")
            return ShutdownVerdict(kind: .unexpected, title: "Stopped without shutting down",
                                   detail: "macOS didn't record an orderly shutdown before this boot, so the Mac most likely lost power, was forced off with the power button, or froze. No panic report was found.",
                                   cause: nil, panic: nil, ended: nil, evidence: evidence, inferred: true)
        }
        return ShutdownVerdict(kind: .unknown, title: hasPrevious ? "Not recorded" : "Before the oldest record",
                               detail: hasPrevious ? "None of macOS's records cover how this session ended (the shutdown log didn't reach back this far and the unified log no longer has this boot)."
                                                   : "This is the oldest boot macOS's login records go back to, so how the session before it ended isn't known.",
                               cause: nil, panic: nil, ended: nil, evidence: evidence, inferred: false)
    }

    /// Counts by verdict title for the "grouped by cause" panel, most frequent first.
    public static func grouped(_ events: [BootEvent]) -> [(title: String, kind: ShutdownVerdict.Kind, count: Int, last: Date)] {
        Dictionary(grouping: events, by: { $0.previous.title }).map { t, es in
            (t, es[0].previous.kind, es.count, es.map(\.boot).max()!)
        }.sorted { ($0.count, $0.last) > ($1.count, $1.last) }
    }
}
