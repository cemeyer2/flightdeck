import Foundation
// Rules: user-defined automatic responses to sustained problems. This file holds the model (`Rule`, stored as JSON in
// user defaults by the app) and `RuleEngine`, which decides when a rule fires. Carrying out the action (notify, renice,
// signal, run a command) is the Engine's job; it re-checks each target's identity before touching it.

/// "When <app/process matching X> has <metric> above <threshold> for <minutes>, do <action>."
/// Raw values of the nested enums are user-facing labels and are also what gets encoded, so renaming one breaks
/// decoding of saved rules.
public struct Rule: Codable, Sendable, Identifiable, Hashable {
    /// `.app` aggregates all processes of an app (see `AppUsage`); `.process` evaluates each process on its own.
    public enum Target: String, Codable, Sendable, CaseIterable, Identifiable { case app = "App", process = "Process"; public var id: String { rawValue } }
    /// The unit is part of each label; `value(_:...)` converts raw samples into it.
    public enum Metric: String, Codable, Sendable, CaseIterable, Identifiable {
        case cpu = "CPU %", memory = "Memory (GB)", gpu = "GPU %", energy = "Energy (W)", wakeups = "Wake-ups /s", disk = "Disk (MB/s)", network = "Network (MB/s)"
        public var id: String { rawValue }
    }
    public enum Action: String, Codable, Sendable, CaseIterable, Identifiable {
        case notify = "Notify me", lowerPriority = "Lower its priority", suspend = "Suspend it", quit = "Quit it", forceQuit = "Force quit it", command = "Run a command"
        public var id: String { rawValue }
        /// Actions that can lose the user's work; the Rules view highlights them and shows a warning in the editor.
        public var isDestructive: Bool { self == .quit || self == .forceQuit || self == .suspend }
    }

    public var id = UUID()
    public var name: String
    public var enabled = true
    public var target: Target = .app
    /// Case-insensitive substring of the app or process name; empty or "*" matches anything.
    public var match: String = ""
    public var metric: Metric = .cpu
    /// In the metric's unit (e.g. 200 = 200% of one core for `.cpu`, GB for `.memory`). Fires only when strictly above.
    public var threshold: Double = 200
    /// How long the value must stay above `threshold` without a break before the rule fires.
    public var minutes: Double = 10
    public var action: Action = .notify
    /// Shell command for `.command`, run with /bin/sh -c; details are passed in FD_* environment variables.
    public var command: String = ""
    /// Minimum time between two firings for the same subject, even across separate occurrences.
    public var cooldownMinutes: Double = 30

    public init(name: String, enabled: Bool = true, target: Target = .app, match: String = "", metric: Metric = .cpu, threshold: Double = 200,
                minutes: Double = 10, action: Action = .notify, command: String = "", cooldownMinutes: Double = 30) {
        self.name = name; self.enabled = enabled; self.target = target; self.match = match; self.metric = metric
        self.threshold = threshold; self.minutes = minutes; self.action = action; self.command = command; self.cooldownMinutes = cooldownMinutes
    }

    /// The rule read back as a sentence, for lists and confirmation text.
    public var sentence: String {
        let who = match.isEmpty || match == "*" ? "any \(target.rawValue.lowercased())" : "\(target.rawValue.lowercased()) “\(match)”"
        let mins = minutes == 1 ? "1 minute" : "\(minutes.formatted()) minutes"
        return "When \(who) has \(metric.rawValue) above \(threshold.formatted()) for \(mins): \(action.rawValue.lowercased())"
    }

    /// Case-insensitive (locale-aware) substring match on the app or process name, ignoring surrounding spaces.
    func matches(_ name: String) -> Bool {
        let m = match.trimmingCharacters(in: .whitespaces)
        return m.isEmpty || m == "*" || name.localizedCaseInsensitiveContains(m)
    }

    /// Converts raw sample values into the metric's display unit (bytes -> GB, bytes/s -> MB/s, both 1024-based).
    /// Missing GPU/energy readings become 0, which simply never exceeds a positive threshold, so such rules never fire
    /// on unknown data.
    static func value(_ m: Metric, cpu: Double, memory: UInt64, gpu: Double?, energy: Double?, wakeups: Double, disk: Double, net: Double) -> Double {
        switch m {
        case .cpu: cpu; case .memory: Double(memory) / 1_073_741_824; case .gpu: gpu ?? 0; case .energy: energy ?? 0
        case .wakeups: wakeups; case .disk: disk / 1_048_576; case .network: net / 1_048_576
        }
    }
}

/// One decision to act: which rule, on what, and the exact processes (PID + start time) to act on.
public struct RuleFiring: Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var rule: Rule
    /// Display name of the app or process.
    public var subject: String
    /// Identities as of the triggering snapshot, so the action can refuse a PID that has since been reused.
    public var targets: [ProcessIdentity]
    /// The metric's value (in its display unit) in the snapshot that triggered the firing.
    public var value: Double
    public var time: Date
}

/// Evaluates rules against each snapshot. Never targets FlightDeck itself or core system processes.
/// Not thread-safe; confine to the sampling queue.
public final class RuleEngine: @unchecked Sendable {
    public var rules: [Rule] = []
    /// Never matched by any rule: killing or suspending these would hang or log out the Mac, or stop FlightDeck itself.
    public static let protected: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow", "FlightDeck", "Flightdeck", "logd", "configd", "powerd"]
    // All three are keyed "<rule id>|<subject key>"; subject keys are the app id or "<pid>-<start time>".
    private var since: [String: Date] = [:]          // rule+subject -> condition true since
    private var fired: [String: Date] = [:]          // rule+subject -> occurrence already handled (since date)
    private var lastFire: [String: Date] = [:]       // rule+subject -> last fire time (cooldown)
    private var last: Date?
    public init() {}

    /// Returns the rules that fire on this snapshot. Called on the sampling queue right after the Analyzer; the Engine
    /// then performs the actions on the main actor. Uses the snapshot's time, so it also works on replayed frames.
    public func evaluate(_ s: Snapshot) -> [RuleFiring] {
        let t = s.time
        // After a gap (sleep, pause) we don't know whether the condition held, so every countdown restarts. `lastFire` is
        // kept, so the cooldown still applies across the gap.
        if let last, t.timeIntervalSince(last) > 120 { since = [:]; fired = [:] }   // gaps break "for N minutes"
        last = t
        // Protection is applied before matching, so even a "*" rule can never select FlightDeck, launchd (pid 1),
        // the kernel (pid 0) or the protected system processes.
        let me = getpid()
        let procs = s.processes.filter { $0.pid > 1 && $0.pid != me && !Self.protected.contains($0.name) }
        var out: [RuleFiring] = []
        var seen = Set<String>()
        for r in rules where r.enabled {
            var subjects: [(key: String, name: String, value: Double, targets: [ProcessIdentity])] = []
            switch r.target {
            case .process:
                for p in procs where r.matches(p.name) {
                    let v = Rule.value(r.metric, cpu: p.cpu, memory: p.memory, gpu: p.gpu, energy: p.energyWatts, wakeups: p.wakeups,
                                       disk: p.diskReadBps + p.diskWriteBps, net: (p.network?.inBps ?? 0) + (p.network?.outBps ?? 0))
                    // Keyed by PID + start time: a relaunched process (or a reused PID) starts its own countdown.
                    subjects.append(("\(p.identity.pid)-\(p.identity.startTime)", p.name, v, [p.identity]))
                }
            case .app:
                let keys = AppUsage.groupKeys(procs)
                for a in AppUsage.aggregate(procs) where r.matches(a.name) {
                    let v = Rule.value(r.metric, cpu: a.cpu, memory: a.memory, gpu: a.gpu, energy: a.energyWatts, wakeups: a.wakeups, disk: a.diskBps, net: a.netBps)
                    // Every member process, so actions such as Quit reach all of an app's helpers.
                    let ids = zip(procs, keys).filter { $0.1.key == a.id }.map(\.0.identity)
                    subjects.append((a.id, a.name, v, ids))
                }
            }
            // Each (rule, subject) pair is tracked separately so one app crossing the line doesn't start or reset another's
            // timer. Subjects under the threshold are skipped, which also drops them from `since` below, so a dip
            // below the line restarts the "for N minutes" countdown.
            for sub in subjects {
                let k = "\(r.id)|\(sub.key)"
                guard sub.value > r.threshold else { continue }
                seen.insert(k)
                let start = since[k] ?? t; since[k] = start
                // Fire at most once per occurrence: `fired` remembers the start of the occurrence already handled. It is
                // set before the cooldown check, so an occurrence that reaches its time during the cooldown is consumed
                // without firing, and does not fire later even if it keeps going after the cooldown ends.
                guard t.timeIntervalSince(start) >= r.minutes * 60, fired[k] != start else { continue }
                fired[k] = start
                if let lf = lastFire[k], t.timeIntervalSince(lf) < r.cooldownMinutes * 60 { continue }
                lastFire[k] = t
                out.append(RuleFiring(rule: r, subject: sub.name, targets: sub.targets, value: sub.value, time: t))
            }
        }
        // Forget countdowns for subjects that are below threshold, gone, or belong to a disabled/deleted rule.
        since = since.filter { seen.contains($0.key) }
        fired = fired.filter { seen.contains($0.key) }
        return out
    }

    /// Decodes saved rules; missing or corrupt data yields no rules rather than an error.
    public static func load(_ data: Data?) -> [Rule] { data.flatMap { try? JSONDecoder().decode([Rule].self, from: $0) } ?? [] }
    public static func save(_ rules: [Rule]) -> Data? { try? JSONEncoder().encode(rules) }

    /// Starter rules behind "Add Examples" in the Rules view, all disabled so nothing happens until the user opts in.
    public static let examples: [Rule] = [
        Rule(name: "Runaway app", enabled: false, target: .app, metric: .cpu, threshold: 300, minutes: 10, action: .notify),
        Rule(name: "Memory hog", enabled: false, target: .app, metric: .memory, threshold: 16, minutes: 5, action: .notify),
        Rule(name: "Tame background indexing", enabled: false, target: .process, match: "mds_stores", metric: .cpu, threshold: 80, minutes: 5, action: .lowerPriority),
    ]
}
