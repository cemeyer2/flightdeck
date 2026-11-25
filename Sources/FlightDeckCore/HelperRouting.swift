import Foundation

// Where root-helper data may go. Counters persist like the app's own (recordings, black box, incident log,
// Prometheus); contents (arguments, environment, files, stacks of other users' processes) are live-only and never
// reach ProcessSample, Copy Summary or any saved file. The web dashboard gets no helper values at all.

public extension Snapshot {
    /// For outputs that must carry no helper data (the web dashboard): drops every process whose counters came from
    /// the helper. Processes the app measured itself are kept, except that another user's thread count is zeroed:
    /// the app can't read it without root (task info is refused), so a nonzero one there came from the helper even
    /// when the app's own rusage read the rest of the row.
    func withoutHelperValues(ownUID: UInt32 = getuid()) -> Snapshot {
        var s = self
        s.processes = s.processes.filter(\.isAppMeasured).map { p in
            var p = p
            if ownUID != 0, p.uid != ownUID { p.threads = 0 }
            return p
        }
        return s
    }
}

/// The inspector's Copy Summary text. It takes only the sample and the app's own ProcessDetails, so the helper's
/// process contents can't end up on the clipboard.
public enum ProcessSummaryText {
    public static func make(_ s: ProcessSample, details: ProcessDetails?) -> String {
        var out = "\(s.name) (PID \(s.pid), parent \(s.ppid), user \(s.user))\n\(s.path)\n"
        out += String(format: "CPU %.1f%%, memory %@, threads %d, CPU time %@\n", s.cpu, Fmt.bytes(s.memory), s.threads, Fmt.duration(s.cpuTime))
        if let a = details?.arguments.value { out += "Arguments: \(a.joined(separator: " "))\n" }
        if let sig = details?.signature { out += "Signature: \(sig.summary)\n" }
        return out
    }
}
