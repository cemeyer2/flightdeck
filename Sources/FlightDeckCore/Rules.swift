import Foundation

/// "When <app/process matching X> has <metric> above <threshold> for <minutes>, do <action>."
public struct Rule: Codable, Sendable, Identifiable, Hashable {
    public enum Target: String, Codable, Sendable, CaseIterable, Identifiable { case app = "App", process = "Process"; public var id: String { rawValue } }
    public enum Metric: String, Codable, Sendable, CaseIterable, Identifiable {
        case cpu = "CPU %", memory = "Memory (GB)", gpu = "GPU %", energy = "Energy (W)", wakeups = "Wake-ups /s", disk = "Disk (MB/s)", network = "Network (MB/s)"
        public var id: String { rawValue }
    }
    public enum Action: String, Codable, Sendable, CaseIterable, Identifiable {
        case notify = "Notify me", lowerPriority = "Lower its priority", suspend = "Suspend it", quit = "Quit it", forceQuit = "Force quit it", command = "Run a command"
        public var id: String { rawValue }
        public var isDestructive: Bool { self == .quit || self == .forceQuit || self == .suspend }
    }

    public var id = UUID()
    public var name: String
    public var enabled = true
    public var target: Target = .app
    /// Case-insensitive substring of the app or process name; empty or "*" matches anything.
    public var match: String = ""
    public var metric: Metric = .cpu
    public var threshold: Double = 200
    public var minutes: Double = 10
    public var action: Action = .notify
    public var command: String = ""
    public var cooldownMinutes: Double = 30

    public init(name: String, enabled: Bool = true, target: Target = .app, match: String = "", metric: Metric = .cpu, threshold: Double = 200,
                minutes: Double = 10, action: Action = .notify, command: String = "", cooldownMinutes: Double = 30) {
        self.name = name; self.enabled = enabled; self.target = target; self.match = match; self.metric = metric
        self.threshold = threshold; self.minutes = minutes; self.action = action; self.command = command; self.cooldownMinutes = cooldownMinutes
    }

    public var sentence: String {
        let who = match.isEmpty || match == "*" ? "any \(target.rawValue.lowercased())" : "\(target.rawValue.lowercased()) “\(match)”"
        let mins = minutes == 1 ? "1 minute" : "\(minutes.formatted()) minutes"
        return "When \(who) has \(metric.rawValue) above \(threshold.formatted()) for \(mins): \(action.rawValue.lowercased())"
    }

    func matches(_ name: String) -> Bool {
        let m = match.trimmingCharacters(in: .whitespaces)
        return m.isEmpty || m == "*" || name.localizedCaseInsensitiveContains(m)
    }

    static func value(_ m: Metric, cpu: Double, memory: UInt64, gpu: Double?, energy: Double?, wakeups: Double, disk: Double, net: Double) -> Double {
        switch m {
        case .cpu: cpu; case .memory: Double(memory) / 1_073_741_824; case .gpu: gpu ?? 0; case .energy: energy ?? 0
        case .wakeups: wakeups; case .disk: disk / 1_048_576; case .network: net / 1_048_576
        }
    }
}

public struct RuleFiring: Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var rule: Rule
    public var subject: String
    public var targets: [ProcessIdentity]
    public var value: Double
    public var time: Date
}

/// Evaluates rules against each snapshot. Never targets FlightDeck itself or core system processes.
/// Not thread-safe; confine to the sampling queue.
public final class RuleEngine: @unchecked Sendable {
    public var rules: [Rule] = []
    public static let protected: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow", "FlightDeck", "Flightdeck", "logd", "configd", "powerd"]
    private var since: [String: Date] = [:]          // rule+subject -> condition true since
    private var fired: [String: Date] = [:]          // rule+subject -> occurrence already handled (since date)
    private var lastFire: [String: Date] = [:]       // rule+subject -> last fire time (cooldown)
    private var last: Date?
    public init() {}

    public func evaluate(_ s: Snapshot) -> [RuleFiring] {
        let t = s.time
        if let last, t.timeIntervalSince(last) > 120 { since = [:]; fired = [:] }   // gaps break "for N minutes"
        last = t
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
                    subjects.append(("\(p.identity.pid)-\(p.identity.startTime)", p.name, v, [p.identity]))
                }
            case .app:
                let keys = AppUsage.groupKeys(procs)
                for a in AppUsage.aggregate(procs) where r.matches(a.name) {
                    let v = Rule.value(r.metric, cpu: a.cpu, memory: a.memory, gpu: a.gpu, energy: a.energyWatts, wakeups: a.wakeups, disk: a.diskBps, net: a.netBps)
                    let ids = zip(procs, keys).filter { $0.1.key == a.id }.map(\.0.identity)
                    subjects.append((a.id, a.name, v, ids))
                }
            }
            for sub in subjects {
                let k = "\(r.id)|\(sub.key)"
                guard sub.value > r.threshold else { continue }
                seen.insert(k)
                let start = since[k] ?? t; since[k] = start
                guard t.timeIntervalSince(start) >= r.minutes * 60, fired[k] != start else { continue }
                fired[k] = start
                if let lf = lastFire[k], t.timeIntervalSince(lf) < r.cooldownMinutes * 60 { continue }
                lastFire[k] = t
                out.append(RuleFiring(rule: r, subject: sub.name, targets: sub.targets, value: sub.value, time: t))
            }
        }
        since = since.filter { seen.contains($0.key) }
        fired = fired.filter { seen.contains($0.key) }
        return out
    }

    public static func load(_ data: Data?) -> [Rule] { data.flatMap { try? JSONDecoder().decode([Rule].self, from: $0) } ?? [] }
    public static func save(_ rules: [Rule]) -> Data? { try? JSONEncoder().encode(rules) }

    public static let examples: [Rule] = [
        Rule(name: "Runaway app", enabled: false, target: .app, metric: .cpu, threshold: 300, minutes: 10, action: .notify),
        Rule(name: "Memory hog", enabled: false, target: .app, metric: .memory, threshold: 16, minutes: 5, action: .notify),
        Rule(name: "Tame background indexing", enabled: false, target: .process, match: "mds_stores", metric: .cpu, threshold: 80, minutes: 5, action: .lowerPriority),
    ]
}
