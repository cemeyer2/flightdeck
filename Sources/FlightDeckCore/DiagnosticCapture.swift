import Foundation
import Darwin

// One-click diagnostic capture ("Capture Diagnostics…"): gathers what someone helping you would ask for into one folder
// (optionally zipped): the last 10 minutes of the black box, a plain-text summary, recent macOS diagnostic reports,
// call stacks of the busiest and any hung processes, and recent error/fault log messages. Everything here blocks for
// seconds (sample, log show), so the app runs `run` on a background task. Only the user's own processes are sampled.
// The output can contain personal paths, user and computer names: the UI says so and asks the user to review it.

public enum DiagnosticCapture {
    /// One step of the capture, reported to the UI as it starts and finishes.
    public struct Step: Sendable, Identifiable, Hashable {
        public enum State: Sendable, Hashable { case pending, running, done, skipped, failed }
        public var id: String
        public var title: String
        public var state: State = .pending
        /// What was written, or why the step was skipped/failed.
        public var detail: String?
        public init(id: String, title: String) { self.id = id; self.title = title }
    }

    /// A process to sample: its identity is re-checked right before `sample` runs, so a recycled PID is never sampled.
    public struct Target: Sendable, Hashable {
        public var identity: ProcessIdentity
        public var name: String
        public var reason: String
        public init(identity: ProcessIdentity, name: String, reason: String) { self.identity = identity; self.name = name; self.reason = reason }
    }

    /// Everything the capture needs from the app, gathered on the main actor before it starts.
    public struct Input: Sendable {
        /// Last 10 minutes of the black box (nil: off or empty, recorded as skipped).
        public var blackBox: Trace?
        public var summary: String
        public var targets: [Target]
        public var reportsSince: Date
        public init(blackBox: Trace?, summary: String, targets: [Target], reportsSince: Date) {
            self.blackBox = blackBox; self.summary = summary; self.targets = targets; self.reportsSince = reportsSince
        }
    }

    /// Caps keep a capture shareable: log output is cut at `logBytes`, at most `maxReports` reports are copied and
    /// any single report larger than `reportBytes` is truncated.
    public static let logBytes = 8 * 1_048_576
    public static let maxReports = 60
    public static let reportBytes = 4 * 1_048_576

    /// The steps in order, all pending. The UI shows this list before and during the capture.
    public static func steps(_ input: Input) -> [Step] {
        [Step(id: "blackbox", title: "Black box: last 10 minutes (.flightlog)"),
         Step(id: "summary", title: "Summary: system, findings, top processes"),
         Step(id: "reports", title: "macOS diagnostic reports from the last 24 hours"),
         Step(id: "stacks", title: "Call stacks (sample, 2 s) of \(input.targets.count) of your processes"),
         Step(id: "log", title: "System log errors and faults from the last 5 minutes"),
         Step(id: "readme", title: "README.txt: what is included")]
    }

    /// Selects what to sample: the top 3 processes by CPU and every app the window server reports as hung, owned by
    /// `uid` only (sample can't attach to other users' processes without root, and they aren't the user's to share).
    /// FlightDeck itself (`exclude`) is skipped: during a capture it is busy with the capture.
    public static func targets(_ procs: [ProcessSample], uid: UInt32 = getuid(), exclude: Int32 = getpid(), top: Int = 3) -> [Target] {
        let mine = procs.filter { $0.uid == uid && $0.pid > 0 && $0.pid != exclude && !$0.restricted }
        var out = mine.sorted { $0.cpu > $1.cpu }.prefix(top).map { Target(identity: $0.identity, name: $0.name, reason: String(format: "top CPU, %.0f%%", $0.cpu)) }
        for p in mine where p.notResponding == true && !out.contains(where: { $0.identity == p.identity }) {
            out.append(Target(identity: p.identity, name: p.name, reason: "not responding"))
        }
        return out
    }

    /// Writes the capture into `folder` (created if needed), calling `progress` with each step's new state (on the
    /// calling thread). Returns the final steps. With `zip`, the folder is compressed next to itself with `ditto`
    /// and removed; the returned URL is what the user should look at.
    public static func run(_ input: Input, into folder: URL, zip: Bool, progress: @Sendable (Step) -> Void) -> (url: URL, steps: [Step]) {
        var steps = steps(input)
        func update(_ id: String, _ state: Step.State, _ detail: String? = nil) {
            guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
            steps[i].state = state; steps[i].detail = detail
            progress(steps[i])
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        update("blackbox", .running)
        if let t = input.blackBox {
            do { try t.write(to: folder.appendingPathComponent("blackbox-last-10-minutes.\(Trace.fileExtension)"))
                 update("blackbox", .done, "\(t.frames.count) samples") }
            catch { update("blackbox", .failed, error.localizedDescription) }
        } else { update("blackbox", .skipped, "the black box is off or has no data yet") }

        update("summary", .running)
        do { try input.summary.write(to: folder.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8); update("summary", .done) }
        catch { update("summary", .failed, error.localizedDescription) }

        update("reports", .running)
        let copied = copyReports(since: input.reportsSince, to: folder.appendingPathComponent("DiagnosticReports"))
        update("reports", copied == 0 ? .skipped : .done, copied == 0 ? "none in the last 24 hours (or none readable)" : "\(copied) copied")

        update("stacks", .running)
        let stacksDir = folder.appendingPathComponent("Stacks")
        let sampled = sampleTargets(input.targets, to: stacksDir)
        update("stacks", sampled.isEmpty ? .skipped : .done,
               sampled.isEmpty ? (input.targets.isEmpty ? "no eligible processes" : "sample couldn't attach") : sampled.joined(separator: ", "))

        update("log", .running)
        switch captureLog(to: folder.appendingPathComponent("log-errors-last-5-minutes.txt")) {
        case .some(let (bytes, truncated)): update("log", .done, Fmt.bytes(UInt64(bytes)) + (truncated ? ", cut at \(Fmt.bytes(UInt64(logBytes)))" : ""))
        case .none: update("log", .failed, "log show could not run")
        }

        update("readme", .running)
        let readme = readmeText(steps: steps)
        try? readme.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        update("readme", .done)

        guard zip else { return (folder, steps) }
        let zipURL = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".zip")
        try? fm.removeItem(at: zipURL)
        // ditto is what Finder's "Compress" uses; --keepParent keeps the folder as the archive's top level.
        _ = Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zipURL.path], timeout: 120)
        if fm.fileExists(atPath: zipURL.path) { try? fm.removeItem(at: folder); return (zipURL, steps) }
        return (folder, steps)
    }

    /// Copies reports modified since `since` (newest first, at most `maxReports`), truncating huge ones. Reports the
    /// user can't read (some in /Library) are skipped. Returns how many were copied.
    static func copyReports(since: Date, to dir: URL) -> Int {
        var files: [(URL, Date)] = []
        for d in DiagnosticReports.directories {
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: d), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for u in urls where ["ips", "diag", "hang", "crash", "spin", "panic"].contains(u.pathExtension) {
                guard let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m >= since else { continue }
                files.append((u, m))
            }
        }
        guard !files.isEmpty else { return 0 }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var n = 0
        for (u, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(maxReports) {
            guard let h = try? FileHandle(forReadingFrom: u) else { continue }
            defer { try? h.close() }
            guard let data = try? h.read(upToCount: reportBytes) else { continue }
            // The system folder and the user folder can hold files with the same name; prefix the system ones.
            let name = (u.path.hasPrefix("/Library") ? "system-" : "") + u.lastPathComponent
            if (try? data.write(to: dir.appendingPathComponent(name))) != nil { n += 1 }
        }
        return n
    }

    /// Runs `sample <pid> 2` for each target in parallel (each takes ~2 s plus symbolication), after re-checking its
    /// identity. Returns "name (pid)" for each successful capture.
    static func sampleTargets(_ targets: [Target], to dir: URL) -> [String] {
        guard !targets.isEmpty else { return [] }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = NSLock()
        var done: [String] = []
        DispatchQueue.concurrentPerform(iterations: targets.count) { i in
            let t = targets[i]
            guard ProcessSampler.identity(of: t.identity.pid) == t.identity else { return }
            let safe = t.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let out = dir.appendingPathComponent("\(safe)-\(t.identity.pid).sample.txt")
            _ = Shell.run("/usr/bin/sample", ["\(t.identity.pid)", "2", "-mayDie", "-file", out.path], timeout: 60)
            if FileManager.default.fileExists(atPath: out.path) {
                lock.lock(); done.append("\(t.name) (\(t.identity.pid), \(t.reason))"); lock.unlock()
            }
        }
        return done
    }

    /// `log show --last 5m --style compact` filtered to errors and faults, streamed to `file` and cut at `logBytes`
    /// (the tool is stopped once the cap is reached). Returns (bytes written, truncated) or nil if log couldn't start.
    static func captureLog(to file: URL, limit: Int = logBytes) -> (Int, Bool)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["show", "--last", "5m", "--style", "compact", "--predicate", "messageType == error OR messageType == fault"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard FileManager.default.createFile(atPath: file.path, contents: nil), let out = try? FileHandle(forWritingTo: file) else { return nil }
        defer { try? out.close() }
        do { try p.run() } catch { return nil }
        // A stuck `log` is stopped after 2 minutes; whatever it wrote is kept.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: killer)
        var written = 0, truncated = false
        let reader = pipe.fileHandleForReading
        while true {
            let chunk = reader.availableData   // blocks until data or EOF
            if chunk.isEmpty { break }
            let room = limit - written
            out.write(chunk.prefix(room)); written += min(chunk.count, room)
            if chunk.count >= room { truncated = true; p.terminate(); break }
        }
        if truncated { out.write(Data("\n[… cut at \(Fmt.bytes(UInt64(limit))) by FlightDeck]\n".utf8)) }
        p.waitUntilExit(); killer.cancel()
        return (written, truncated)
    }

    /// The README placed in the capture: what each file is, what was skipped, and the privacy note.
    static func readmeText(steps: [Step]) -> String {
        var s = """
        FlightDeck diagnostic capture, \(Date().formatted(date: .complete, time: .standard))

        PLEASE REVIEW BEFORE SHARING. These files can contain personal information: file paths with your user name,
        your computer name, app and document names, process arguments, and log messages from apps and macOS.

        Contents:
          blackbox-last-10-minutes.flightlog   open in FlightDeck (File › Open Trace) to replay the last 10 minutes
          summary.txt                          system information, current findings and the busiest processes
          DiagnosticReports/                   copies of macOS crash, hang and resource reports from the last 24 hours
          Stacks/                              call stacks (/usr/bin/sample, 2 s) of the busiest and any hung processes you own
          log-errors-last-5-minutes.txt        `log show --last 5m` errors and faults (capped in size)

        What happened:

        """
        for st in steps where st.id != "readme" {
            let state: String
            switch st.state { case .done: state = "included"; case .skipped: state = "skipped"; case .failed: state = "failed"; case .pending, .running: state = "not run" }
            s += "  [\(state)] \(st.title)" + (st.detail.map { ": \($0)" } ?? "") + "\n"
        }
        return s
    }

    /// The plain-text summary: system facts (without serial number or hardware UUID), the current findings, and the
    /// top processes by CPU and by memory. Unmeasured values print as "—".
    public static func summaryText(snapshot s: Snapshot?, findings: [Finding], info: [InfoItem], now: Date = Date()) -> String {
        var out = "FlightDeck summary, \(now.formatted(date: .complete, time: .standard))\n\n"
        out += "SYSTEM\n"
        // Identifiers that single out this Mac are left out on purpose.
        for i in info where !["Serial Number", "Hardware UUID"].contains(i.key) { out += "  \(i.section) › \(i.key): \(i.value)\n" }
        guard let s else { return out + "\nNo sample was available.\n" }
        func m(_ v: Double?, _ f: String) -> String { v.map { String(format: f, $0) } ?? "—" }
        out += "\nNOW (sample at \(s.time.formatted(date: .omitted, time: .standard)))\n"
        out += "  CPU \(m(s.cpu.total.value, "%.1f%%")), load \(s.cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " "))\n"
        out += "  Memory \(Fmt.bytes(s.memory.used)) of \(Fmt.bytes(s.memory.total)), pressure \(m(s.memory.pressure.value, "%.0f%%")), swap \(s.memory.swapUsed.value.map(Fmt.bytes) ?? "—")\n"
        out += "  Disk read \(s.disk.readBps.value.map(Fmt.rate) ?? "—"), write \(s.disk.writeBps.value.map(Fmt.rate) ?? "—")\n"
        out += "  Network in \(s.network.inBps.value.map(Fmt.rate) ?? "—"), out \(s.network.outBps.value.map(Fmt.rate) ?? "—")\n"
        out += "  Power \(m(s.power.systemWatts.value, "%.1f W")), hottest \(m(s.power.hottest.value, "%.0f °C")), thermal state \(["nominal", "fair", "serious", "critical"][min(max(s.power.thermalState, 0), 3)])\n"
        out += "\nFINDINGS\n"
        if findings.isEmpty { out += "  None: no sustained problems right now.\n" }
        for f in findings.sorted(by: { $0.severity > $1.severity }) {
            out += "  [\(["", "info", "caution", "warning"][f.severity.rawValue])] \(f.title) (since \(f.since.formatted(date: .omitted, time: .shortened)))\n"
            if let d = f.detail { out += "      \(d)\n" }
        }
        func table(_ title: String, _ ps: [ProcessSample]) {
            out += "\n\(title)\n  " + "PID".padding(toLength: 8, withPad: " ", startingAt: 0) + "CPU%    MEMORY      USER        NAME\n"
            for p in ps {
                out += "  " + "\(p.pid)".padding(toLength: 8, withPad: " ", startingAt: 0)
                    + String(format: "%-8.1f", p.cpu) + (p.restricted && p.memory == 0 ? "—" : Fmt.bytes(p.memory)).padding(toLength: 12, withPad: " ", startingAt: 0)
                    + p.user.padding(toLength: 12, withPad: " ", startingAt: 0) + p.name
                    + (p.notResponding == true ? "  [NOT RESPONDING]" : "") + "\n"
            }
        }
        table("TOP PROCESSES BY CPU", Array(s.processes.sorted { $0.cpu > $1.cpu }.prefix(15)))
        table("TOP PROCESSES BY MEMORY", Array(s.processes.sorted { $0.memory > $1.memory }.prefix(15)))
        return out
    }
}
