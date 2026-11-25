import Foundation

// Where root-helper data may go. Counters persist like the app's own (recordings, black box, incident log,
// Prometheus); contents (arguments, environment, files, stacks of other users' processes) are live-only and never
// reach ProcessSample, Copy Summary or any saved file. The web dashboard gets no helper values at all.

public extension Snapshot {
    /// For outputs that must carry no helper data (the web dashboard): drops every process whose counters came from
    /// the helper. Processes the app measured itself are kept as they are.
    func withoutHelperValues() -> Snapshot {
        var s = self
        s.processes = s.processes.filter(\.isAppMeasured)
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
