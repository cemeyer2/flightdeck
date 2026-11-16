import Foundation

/// Turns `/usr/bin/sample` output into a one-line "where is the time going" summary.
public enum StackSummary {
    /// Frames that mean "this thread is waiting", not computing.
    static let waits = ["mach_msg", "__psynch_cvwait", "__psynch_mutexwait", "__ulock_wait", "semaphore_wait", "kevent", "__select",
                        "__workq_kernreturn", "__semwait_signal", "poll", "read", "__recvfrom", "pthread_cond_wait", "_dispatch_semaphore_wait"]
    static let noise = ["start", "main", "thread_start", "_pthread_start", "NSApplicationMain", "-[NSApplication run]", "RunCurrentEventLoopInMode",
                        "ReceiveNextEventCommon", "_DPSNextEvent", "CFRunLoopRunSpecific", "__CFRunLoopRun", "__CFRunLoopServiceMachPort",
                        "_BlockUntilNextEventMatchingListInModeWithFilter", "-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]",
                        "_dispatch_main_queue_drain", "_dispatch_main_queue_callback_4CF", "__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__"]

    struct Frame { var depth: Int; var count: Int; var symbol: String; var library: String? }

    static func frames(of section: [Substring]) -> [Frame] {
        section.compactMap { line in
            guard let firstDigit = line.firstIndex(where: \.isNumber) else { return nil }
            let depth = line.distance(from: line.startIndex, to: firstDigit)
            let rest = line[firstDigit...]
            let parts = rest.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let count = Int(parts[0]) else { return nil }
            var sym = String(parts[1])
            var lib: String?
            if let r = sym.range(of: "  (in ") {
                lib = sym[r.upperBound...].split(separator: ")").first.map(String.init)
                sym = String(sym[..<r.lowerBound])
            }
            return Frame(depth: depth, count: count, symbol: sym.trimmingCharacters(in: .whitespaces), library: lib)
        }
    }

    /// Heaviest path of the main thread (sample lists the busiest child first, so it's the run of lines whose depth keeps growing).
    public static func summarize(_ sample: String) -> String? {
        let lines = sample.split(separator: "\n")
        // "Main Thread" in apps, just the main dispatch queue in plain tools; else the first thread of the call graph
        guard let start = lines.firstIndex(where: { $0.contains("Thread_") && ($0.contains("Main Thread") || $0.contains("com.apple.main-thread")) })
                ?? lines.firstIndex(where: { $0.contains("Thread_") }) else { return nil }
        var section: [Substring] = []
        for l in lines[(start + 1)...] {
            if l.contains("Thread_") || l.hasPrefix("Total number in stack") || l.trimmingCharacters(in: .whitespaces).isEmpty { break }
            section.append(l)
        }
        let fs = frames(of: section)
        guard let total = fs.first?.count, total > 0 else { return nil }
        var path: [Frame] = []
        var depth = -1
        for f in fs { if f.depth > depth { path.append(f); depth = f.depth } else { break } }
        guard let leaf = path.last else { return nil }
        let meaningful = path.filter { f in !noise.contains(f.symbol) && !f.symbol.hasPrefix("???") }
        let named = meaningful.suffix(4).reversed().map { f in f.library.map { "\(f.symbol) (\($0))" } ?? f.symbol }
        let waiting = waits.contains { leaf.symbol.hasPrefix($0) || leaf.symbol.contains($0) }
        let share = Int((Double(leaf.count) / Double(total) * 100).rounded())
        let idleLoop = meaningful.isEmpty
        if idleLoop { return "Main thread idle in the event loop (not stuck)" }
        return (waiting ? "Main thread waiting (\(share)% of samples) in " : "Main thread busy (\(share)% of samples) in ")
            + named.joined(separator: " ← ")
    }
}

/// Where captured evidence (stack samples) is kept, next to the incident log.
public enum EvidenceStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flightdeck/Evidence", isDirectory: true)   // folder name predates the FlightDeck capitalisation
    }

    /// Samples `pid` for `seconds` and stores the report; returns (file, summary).
    public static func capture(pid: Int32, name: String, incident: UUID, seconds: Int = 3) -> (URL, String?)? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = ProcessInspector.sampleStacks(pid: pid, seconds: seconds)
        guard text.contains("Call graph") else { return nil }
        let url = directory.appendingPathComponent("\(incident.uuidString)-\(name.replacingOccurrences(of: "/", with: "_"))-\(pid).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return (url, StackSummary.summarize(text))
    }

    /// Deletes evidence older than `days`.
    public static func prune(days: Double = 7) {
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for u in urls where ((try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()) < cutoff {
            try? FileManager.default.removeItem(at: u)
        }
    }
}
