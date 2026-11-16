import Foundation

/// Filter language for the process list. Space-separated terms, all must match:
///   cpu>50  gpu>0  mem>1g  disk>10m  net>100k  threads>100  pid=123  wakeups>500
///   user:root  app:chrome  kind:intel|apple  sleep  hung  restricted
///   anything else: case-insensitive match on name, path, user or exact PID.
public struct ProcessQuery: Sendable {
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

    static func number(_ s: String) -> Double? {
        let t = s.lowercased()
        let mult: [(String, Double)] = [("tb", 1_099_511_627_776), ("t", 1_099_511_627_776), ("gb", 1_073_741_824), ("g", 1_073_741_824), ("mb", 1_048_576), ("m", 1_048_576), ("kb", 1024), ("k", 1024)]
        for (suffix, m) in mult where t.hasSuffix(suffix) { return Double(t.dropLast(suffix.count)).map { $0 * m } }
        return Double(t.replacingOccurrences(of: "%", with: ""))
    }

    static func parse(_ raw: String) -> Term? {
        let t = raw.lowercased()
        if t.isEmpty { return nil }
        switch t { case "sleep", "awake": return .sleep; case "hung", "notresponding": return .hung; case "restricted": return .restricted; default: break }
        for prefix in ["user:", "app:", "kind:"] where t.hasPrefix(prefix) {
            let v = String(t.dropFirst(prefix.count))
            return prefix == "user:" ? .user(v) : prefix == "app:" ? .app(v) : .kind(v)
        }
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

    public func matches(_ p: ProcessSample) -> Bool {
        terms.allSatisfy { term in
            switch term {
            case .compare(let f, let op, let v):
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
            case .kind(let k): return k.hasPrefix("i") || k.hasPrefix("r") ? p.translated == true : p.translated == false
            case .sleep: return p.powerAssertions != nil
            case .hung: return p.notResponding == true
            case .restricted: return p.restricted
            case .text(let s): return p.name.lowercased().contains(s) || p.path.lowercased().contains(s) || p.user.lowercased() == s || "\(p.pid)" == s
            }
        }
    }
}
