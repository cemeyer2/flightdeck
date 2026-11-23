import Foundation
// Automatic evidence for hangs and CPU/GPU hogs: when such an incident is first logged, the Engine samples the
// process's stacks with Apple's `/usr/bin/sample`, stores the report, and attaches a one-line summary to the incident.

/// Turns `/usr/bin/sample` output into a one-line "where is the time going" summary.
public enum StackSummary {
    /// Frames that mean "this thread is waiting", not computing.
    static let waits = ["mach_msg", "__psynch_cvwait", "__psynch_mutexwait", "__ulock_wait", "semaphore_wait", "kevent", "__select",
                        "__workq_kernreturn", "__semwait_signal", "poll", "read", "__recvfrom", "pthread_cond_wait", "_dispatch_semaphore_wait"]
    /// Run-loop and startup plumbing present in nearly every main-thread stack; dropped from the summary so the
    /// named frames are the app's own code.
    static let noise = ["start", "main", "thread_start", "_pthread_start", "NSApplicationMain", "-[NSApplication run]", "RunCurrentEventLoopInMode",
                        "ReceiveNextEventCommon", "_DPSNextEvent", "CFRunLoopRunSpecific", "__CFRunLoopRun", "__CFRunLoopServiceMachPort",
                        "_BlockUntilNextEventMatchingListInModeWithFilter", "-[NSApplication(NSEventRouting) _nextEventMatchingEventMask:untilDate:inMode:dequeue:]",
                        "_dispatch_main_queue_drain", "_dispatch_main_queue_callback_4CF", "__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__",
                        // the run loop's own wait: a main thread sitting here is idle, not stuck
                        "mach_msg", "mach_msg2_trap", "mach_msg_overwrite", "mach_msg2_internal", "__CFRunLoopServiceMachPort"]

    /// One line of sample's call graph. `depth` is the column of the sample count (deeper calls are indented further),
    /// `count` is how many samples were in that frame.
    struct Frame { var depth: Int; var count: Int; var symbol: String; var library: String? }

    /// Whether a leaf frame is a blocking call. Long names match as prefixes (mach_msg2_trap, kevent_qos); short ones
    /// ("read", "poll") only exactly or with a variant suffix ("read$NOCANCEL"), so "pthread_…" or "spread" don't count.
    static func isWait(_ s: String) -> Bool {
        waits.contains { w in s == w || (w.count >= 6 && s.hasPrefix(w)) || s.hasPrefix(w + "_") || s.hasPrefix(w + "$") }
    }

    /// Parses call-graph lines of the form `    + ! : 1234 symbol  (in Library) + 56  [0x...]`. The tree-drawing
    /// characters (`+ ! : |`) are skipped by measuring indentation up to the first digit; lines without a count are dropped.
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
        // The thread's call graph runs until the next thread header, the "Total number in stack" footer, or a blank line.
        var section: [Substring] = []
        for l in lines[(start + 1)...] {
            if l.contains("Thread_") || l.hasPrefix("Total number in stack") || l.trimmingCharacters(in: .whitespaces).isEmpty { break }
            section.append(l)
        }
        let fs = frames(of: section)
        // The thread's root frame carries the total sample count for the thread; shares are relative to it.
        guard let total = fs.first?.count, total > 0 else { return nil }
        var path: [Frame] = []
        var depth = -1
        for f in fs { if f.depth > depth { path.append(f); depth = f.depth } else { break } }
        guard let leaf = path.last else { return nil }
        // Name the four innermost meaningful frames, innermost first (joined with ←). "???" frames have no symbols.
        let meaningful = path.filter { f in !noise.contains(f.symbol) && !f.symbol.hasPrefix("???") }
        let named = meaningful.suffix(4).reversed().map { f in f.library.map { "\(f.symbol) (\($0))" } ?? f.symbol }
        // Waiting vs busy is decided by the leaf (innermost frame of the heaviest path) alone.
        let waiting = isWait(leaf.symbol)
        let share = Int((Double(leaf.count) / Double(total) * 100).rounded())
        // If nothing but run-loop plumbing remains, the thread was just idling in its event loop.
        let idleLoop = meaningful.isEmpty
        if idleLoop { return "Main thread idle in the event loop (not stuck)" }
        return (waiting ? "Main thread waiting (\(share)% of samples) in " : "Main thread busy (\(share)% of samples) in ")
            + named.joined(separator: " ← ")
    }
}

/// Where captured evidence (stack samples) is kept, next to the incident log. Files are named
/// `<incident UUID>-<process name>-<pid>.txt`; the incident stores the full path (`Incident.evidencePath`).
public enum EvidenceStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flightdeck/Evidence", isDirectory: true)   // folder name predates the FlightDeck capitalisation
    }

    /// Samples `pid` for `seconds` and stores the report; returns (file, summary). Blocks for the whole sampling time,
    /// so the Engine calls it on its own utility queue, one capture at a time. Returns nil when sample couldn't attach
    /// (no "Call graph" in the output): processes of other users or SIP-protected ones can't be sampled without root.
    /// The summary is nil if the report could be saved but not parsed.
    public static func capture(pid: Int32, name: String, incident: UUID, seconds: Int = 3) -> (URL, String?)? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = ProcessInspector.sampleStacks(pid: pid, seconds: seconds)
        guard text.contains("Call graph") else { return nil }
        let url = directory.appendingPathComponent("\(incident.uuidString)-\(name.replacingOccurrences(of: "/", with: "_"))-\(pid).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return (url, StackSummary.summarize(text))
    }

    /// Deletes evidence older than `days` (by modification date). Called at launch from the black-box queue. Files whose
    /// date can't be read are kept.
    public static func prune(days: Double = 7) {
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for u in urls where ((try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()) < cutoff {
            try? FileManager.default.removeItem(at: u)
        }
    }
}

/// State of the network stack, saved when an interface loses its address or stops receiving (`net-noip:` and
/// `net-rx-stall:` incidents). A reboot clears all of this, so it is taken while the incident is open. Nothing here needs
/// root. Each command has a short timeout because several of them (scutil, systemextensionsctl) can stall during an outage.
public enum NetworkEvidence {
    /// Process names (lowercased substrings) of VPNs, network filters and security agents worth listing next to the state.
    static let agentKeywords = ["zscaler", "crowdstrike", "falcon", "globalprotect", "pangp", "cyberark", "idira", "tailscale",
                                "wireguard", "openvpn", "vpn", "networkserviceproxy", "nesessionmanager", "configd", "symptomsd"]

    static func commands(interface: String) -> [(title: String, path: String, args: [String])] { [
        ("ifconfig \(interface)", "/sbin/ifconfig", [interface]),
        ("interface counters (netstat -I \(interface) -b -d)", "/usr/sbin/netstat", ["-I", interface, "-b", "-d"]),
        ("DHCP packet (ipconfig getpacket \(interface))", "/usr/sbin/ipconfig", ["getpacket", interface]),
        ("ipconfig getsummary \(interface)", "/usr/sbin/ipconfig", ["getsummary", interface]),
        ("routes (netstat -rn)", "/usr/sbin/netstat", ["-rn"]),
        ("neighbours (arp -an)", "/usr/sbin/arp", ["-an"]),
        ("VPN and network extension connections (scutil --nc list)", "/usr/sbin/scutil", ["--nc", "list"]),
        ("DNS (scutil --dns)", "/usr/sbin/scutil", ["--dns"]),
        ("service order (networksetup -listnetworkserviceorder)", "/usr/sbin/networksetup", ["-listnetworkserviceorder"]),
        ("system extensions (systemextensionsctl list)", "/usr/bin/systemextensionsctl", ["list"]),
    ] }

    /// `ps` lines for VPN, filter and security agents, with their age and CPU, from the full `ps` output.
    static func agentProcesses(_ ps: String) -> String {
        let lines = ps.split(separator: "\n", omittingEmptySubsequences: true)
        let hits = lines.dropFirst().filter { l in let low = l.lowercased(); return agentKeywords.contains { low.contains($0) } }
        return ([lines.first.map(String.init) ?? ""] + hits.map(String.init)).joined(separator: "\n")
    }

    /// One line for the Flight Log: the link, addresses and default route of `interface` at capture time.
    static func summarize(interface: String, ifconfig: String, routes: String) -> String {
        var link = "link unknown"
        if ifconfig.contains("status: active") { link = "link active" } else if ifconfig.contains("status: inactive") { link = "link inactive" }
        let v4 = ifconfig.split(separator: "\n").compactMap { l -> String? in
            let w = l.split(whereSeparator: { $0 == " " || $0 == "\t" })   // ifconfig indents its detail lines with a tab
            return w.count >= 2 && w[0] == "inet" ? String(w[1]) : nil
        }
        let gateway = routes.split(separator: "\n").compactMap { l -> String? in
            let w = l.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return w.count >= 4 && w[0] == "default" && w.last == Substring(interface) ? String(w[1]) : nil
        }.first
        return "\(interface): \(link), " + (v4.isEmpty ? "no IPv4 address" : "IPv4 " + v4.joined(separator: ", "))
            + ", " + (gateway.map { "default route via \($0)" } ?? "no default route on \(interface)")
    }

    /// Runs the commands and stores the report as `<incident UUID>-network-<interface>.txt`; returns (file, summary).
    /// Blocks for as long as the commands take (each is capped at `timeout`), so call it on the evidence queue.
    public static func capture(interface: String, incident: UUID, directory: URL = EvidenceStore.directory, timeout: TimeInterval = 5) -> (URL, String?)? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report = "Network state for \(interface), captured \(Date())\n"
        var ifconfig = "", routes = ""
        for c in commands(interface: interface) {
            let out = Shell.run(c.path, c.args, timeout: timeout)
            report += "\n### \(c.title)\n" + (out ?? "(no output: command failed or timed out after \(Int(timeout)) s)\n")
            if c.path == "/sbin/ifconfig" { ifconfig = out ?? "" }
            if c.args == ["-rn"] { routes = out ?? "" }
        }
        let ps = Shell.run("/bin/ps", ["-axo", "pid,etime,%cpu,state,comm"], timeout: timeout)
        report += "\n### VPN, filter and security processes\n" + (ps.map(agentProcesses) ?? "(ps failed)") + "\n"
        let name = interface.replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent("\(incident.uuidString)-network-\(name).txt")
        do { try report.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return (url, summarize(interface: interface, ifconfig: ifconfig, routes: routes))
    }
}
