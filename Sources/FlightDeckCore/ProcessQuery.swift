import Foundation
// Parser and matcher for the process list's search field. The process outline re-parses the (lowercased) filter on
// each refresh and calls `matches` for every process, so both are kept to cheap string and number comparisons.

/// Filter language for the process list. Space-separated terms, all must match:
///   cpu>50  gpu>0  mem>1g  disk>10m  net>100k  threads>100  pid=123  wakeups>500
///   user:root  app:chrome  kind:intel|apple  sleep  hung  restricted
///   anything else: case-insensitive match on name, path, user or exact PID.
public struct ProcessQuery: Sendable {
    /// One parsed search term. Comparison fields stay as strings and are resolved in `matches`.
    enum Term: Sendable {
        case compare(field: String, op: String, value: Double)
        case user(String), app(String), kind(String), text(String)
        case sleep, hung, restricted
    }
    let terms: [Term]
    public var isEmpty: Bool { terms.isEmpty }

    public init(_ s: String) {
        terms = s.split(separator: " ").compactMap { Self.parse(String($0)) }
    }

    /// Parses a comparison value. Size suffixes are binary (k = 1024, m = 1024², ...), so "mem>1g" means 1 GiB and
    /// "disk>10m" means 10 MiB/s; a trailing % is ignored, so "cpu>50%" works. Returns nil for anything else.
    static func number(_ s: String) -> Double? {
        let t = s.lowercased()
        let mult: [(String, Double)] = [("tb", 1_099_511_627_776), ("t", 1_099_511_627_776), ("gb", 1_073_741_824), ("g", 1_073_741_824), ("mb", 1_048_576), ("m", 1_048_576), ("kb", 1024), ("k", 1024)]
        // Two-letter suffixes are listed before their one-letter forms so "1gb" isn't read as "1g" + junk "b".
        for (suffix, m) in mult where t.hasSuffix(suffix) { return Double(t.dropLast(suffix.count)).map { $0 * m } }
        return Double(t.replacingOccurrences(of: "%", with: ""))
    }

    /// Classifies one lowercased term. Keywords first, then `prefix:value`, then `field<op>number`; anything that
    /// doesn't fit (including an unknown field or unparseable number) falls back to a plain text search.
    static func parse(_ raw: String) -> Term? {
        let t = raw.lowercased()
        if t.isEmpty { return nil }
        switch t { case "sleep", "awake": return .sleep; case "hung", "notresponding": return .hung; case "restricted": return .restricted; default: break }
        for prefix in ["user:", "app:", "kind:"] where t.hasPrefix(prefix) {
            let v = String(t.dropFirst(prefix.count))
            return prefix == "user:" ? .user(v) : prefix == "app:" ? .app(v) : .kind(v)
        }
        // Two-character operators are tried first so "cpu>=50" isn't split at ">" into field "cpu" and value "=50".
        for op in [">=", "<=", ">", "<", "="] {
            if let r = t.range(of: op) {
                let field = String(t[..<r.lowerBound]), val = String(t[r.upperBound...])
                if ["cpu", "gpu", "mem", "memory", "disk", "net", "threads", "pid", "wakeups", "energy"].contains(field), let v = number(val) {
                    return .compare(field: field, op: op, value: v)
                }
            }
        }
        return .text(t)
    }

    /// True if every term matches (AND). An empty query matches everything.
    public func matches(_ p: ProcessSample) -> Bool {
        terms.allSatisfy { term in
            switch term {
            case .compare(let f, let op, let v):
                // Units match ProcessSample: cpu/gpu in % (cpu is % of one core), mem in bytes, disk/net in bytes/s,
                // energy in W. A missing optional reading (gpu, net, energy) compares as 0 here, which suits the usual
                // "above X" filters but means "gpu<1" also lists processes whose GPU use is unknown.
                let x: Double
                switch f {
                case "cpu": x = p.cpu
                case "gpu": x = p.gpu ?? 0
                case "mem", "memory": x = Double(p.memory)
                case "disk": x = p.diskReadBps + p.diskWriteBps
                case "net": x = (p.network?.inBps ?? 0) + (p.network?.outBps ?? 0)
                case "threads": x = Double(p.threads)
                case "pid": x = Double(p.pid)
                case "wakeups": x = p.wakeups
                default: x = p.energyWatts ?? 0
                }
                switch op { case ">": return x > v; case "<": return x < v; case ">=": return x >= v; case "<=": return x <= v; default: return x == v }
            case .user(let u): return p.user.lowercased() == u || p.user.lowercased().hasPrefix(u)
            case .app(let a): return AppUsage.key(for: p).name.lowercased().contains(a)
            // "kind:intel" / "kind:rosetta" select translated (x86) processes; anything else selects native ones. Processes
            // whose architecture is unknown (`translated == nil`) match neither.
            case .kind(let k): return k.hasPrefix("i") || k.hasPrefix("r") ? p.translated == true : p.translated == false
            // "sleep" / "awake": the process holds a power assertion that prevents sleep.
            case .sleep: return p.powerAssertions != nil
            case .hung: return p.notResponding == true
            case .restricted: return p.restricted
            case .text(let s): return p.name.lowercased().contains(s) || p.path.lowercased().contains(s) || p.user.lowercased() == s || "\(p.pid)" == s
            }
        }
    }
}
