// Tests for the slower, on-demand readers behind the Process Inspector and the diagnostics pages: ProcessInspector
// details and signatures, NVMe drive health, SMC fans, per-process counters and power assertions, diagnostic reports,
// startup items, call-stack evidence and the pmset sleep log. Most run against this test process or the real Mac.
import XCTest
@testable import FlightDeckCore

/// Process Inspector details.
final class InspectorTests: XCTestCase {
    /// Opens a listening socket and a file in this process, then checks the inspector sees them along with arguments,
    /// environment, cwd, threads, nice value and an ancestry chain running from this process up to launchd (PID 1).
    func testOwnProcessDetails() throws {
        // open a listening TCP socket and a file so they show up
        let s = socket(AF_INET, SOCK_STREAM, 0); defer { close(s) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(s, 1)
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("insp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: f.path, contents: Data())
        let h = try FileHandle(forReadingFrom: f); defer { try? h.close() }

        let d = ProcessInspector.details(pid: getpid(), path: CommandLine.arguments[0])
        XCTAssertFalse(d.arguments.value?.isEmpty ?? true)
        XCTAssertTrue(d.environment.value?.contains { $0.hasPrefix("PATH=") } ?? false)
        XCTAssertEqual(d.cwd.value, FileManager.default.currentDirectoryPath)
        XCTAssertTrue(d.files.value?.contains { $0.description.hasSuffix(f.lastPathComponent) } ?? false)
        let l = d.sockets.first { $0.proto == "TCP" && $0.state == "LISTEN" }
        XCTAssertNotNil(l, "listening socket: \(d.sockets)")
        XCTAssertTrue(l?.local.hasPrefix("127.0.0.1:") ?? false)
        XCTAssertGreaterThan(d.threads.value?.count ?? 0, 0)
        XCTAssertEqual(d.ancestry.first?.pid, getpid())
        XCTAssertEqual(d.ancestry.last?.pid, 1)
        XCTAssertNotNil(d.nice)
    }

    /// Apple's own binaries verify as Apple-signed, and another user's process (launchd, unless running as root) must
    /// report its environment as unavailable (nil), not as an empty list that would look like "no variables".
    func testSignatureAndRestricted() {
        let sig = ProcessInspector.signature("/usr/bin/yes")
        XCTAssertEqual(sig?.isApple, true)
        XCTAssertEqual(sig?.valid, true)
        if getuid() != 0 {
            let d = ProcessInspector.details(pid: 1, path: "/sbin/launchd")
            XCTAssertNil(d.environment.value, "another user's environment must be unavailable, not empty")
        }
    }

    /// A team ID counts only on an Apple-issued certificate for that team: an Apple platform binary (no team) and an
    /// ad-hoc signed copy are not anchored to any team; a Developer ID app, when installed, is anchored to its own team only.
    func testTeamAnchored() throws {
        XCTAssertFalse(ProcessInspector.isAnchored("/bin/ls", team: "ABCDE12345"))
        XCTAssertEqual(ProcessInspector.signature("/bin/ls")?.teamAnchored, false)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-adhoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("ls").path
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: bin)
        _ = Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", bin])
        XCTAssertEqual(ProcessInspector.signature(bin)?.valid, true)
        XCTAssertFalse(ProcessInspector.isAnchored(bin, team: "ABCDE12345"))
        // Spliced in unchecked, this makes a valid requirement that /bin/ls satisfies ("… or always or …").
        XCTAssertFalse(ProcessInspector.isAnchored("/bin/ls", team: "X\" or always or certificate leaf[subject.OU] = \"X"),
                       "a team ID is never spliced into the requirement unchecked")
        let chrome = "/Applications/Google Chrome.app"
        guard FileManager.default.fileExists(atPath: chrome) else { throw XCTSkip("no Developer ID app to check") }
        XCTAssertTrue(ProcessInspector.isAnchored(chrome, team: "EQHXZ8M8AV"))
        XCTAssertFalse(ProcessInspector.isAnchored(chrome, team: "ABCDE12345"))
        XCTAssertEqual(ProcessInspector.signature(chrome)?.teamAnchored, true)
    }
}

/// NVMe SMART health.
final class DriveHealthTests: XCTestCase {
    /// On Macs that expose SMART data, the decoded values are plausible (non-zero writes and power-on hours, a sane
    /// temperature); Macs without it must return an empty list rather than fabricated readings.
    func testReadsInternalSSD() {
        let d = DriveHealthReader.read()
        print("DRIVES", d)
        guard let first = d.first else { return }   // Macs without NVMe SMART simply report nothing
        XCTAssertGreaterThan(first.bytesWritten, 0)
        XCTAssertGreaterThan(first.powerOnHours, 0)
        XCTAssert((0...150).contains(first.temperature))
    }
}

/// SMC fan decoding.
final class SMCTests: XCTestCase {
    /// Fan RPMs decode to plausible numbers (a wrong SMC data-type decode shows up as absurd values). Fanless Macs pass
    /// trivially with no fans.
    func testFansDecode() {
        let f = SMC.shared.fans()
        print("FANS", f)
        for fan in f { XCTAssert((0...20_000).contains(fan.rpm)); if let m = fan.maxRPM { XCTAssertGreaterThan(m, 500) } }
    }
}

import IOKit.pwr_mgt
/// Per-process kernel counters, Rosetta detection and sleep-prevention assertions.
final class ProcessExtrasTests: XCTestCase {
    /// Task info and proc_pid_rusage counters are read for this process, a native test binary isn't reported as
    /// translated, and a power assertion this process creates is attributed to its PID by name and type, end-to-end
    /// through the Sampler.
    func testCountersKindAndAssertions() {
        let c = ProcessInspector.counters(getpid())
        XCTAssertNotNil(c); XCTAssertGreaterThan(c!.unixSyscalls, 0); XCTAssertGreaterThan(c!.peakFootprint ?? 0, 0)
        XCTAssertEqual(ProcessSampler.isTranslated(getpid()), false)
        var id: IOPMAssertionID = 0
        XCTAssertEqual(IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "flightdeck test" as CFString, &id), kIOReturnSuccess)
        defer { IOPMAssertionRelease(id) }
        let mine = PowerAssertions.byPID()[getpid()]
        XCTAssertEqual(mine?.first?.name, "flightdeck test")
        XCTAssertTrue(mine?.first?.preventsSystemSleep ?? false)
        let s = Sampler().sample().processes.first { $0.pid == getpid() }
        XCTAssertNotNil(s?.powerAssertions)
        XCTAssertEqual(s?.translated, false)
    }
}

/// DiagnosticReports parsing from synthetic files in a temporary directory.
final class DiagnosticReportTests: XCTestCase {
    /// Writes a report file with the given contents into `dir`.
    func write(_ name: String, _ s: String, in dir: URL) { try! s.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }

    /// Covers both formats macOS writes: JSON `.ips` (crash, simulated user fault, jetsam) and text `.diag` (disk-write
    /// limit). Checks kind classification, process attribution (jetsam reports belong to "System"), summaries, and
    /// that of these only the repeated crash becomes a finding, counted per app.
    func testParsesKindsAndFindings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        let ts = DiagnosticReports.headerDate.string(from: now.addingTimeInterval(-600))
        for i in 0..<2 {
            write("Foo-\(i).ips", #"{"app_name":"Foo","timestamp":"\#(ts)","bug_type":"309","name":"Foo"}"# + "\n{\n  \"exception\" : {\"codes\":\"0x1\", \"type\" : \"EXC_BAD_ACCESS\", \"signal\" : \"SIGSEGV\"}\n}", in: dir)
        }
        write("ExcUserFault_bar.ips", #"{"is_simulated":1,"app_name":"bar","timestamp":"\#(ts)","bug_type":"309"}"# + "\n{}", in: dir)
        write("JetsamEvent-x.ips", #"{"bug_type":"298","timestamp":"\#(ts)"}"# + "\n{}", in: dir)
        write("curl_x.diag", "Date/Time:        \(DiagnosticReports.textDate.string(from: now))\nCommand:          curl\nEvent:            disk writes\nWrites:           8589.94 MB of file backed memory dirtied\n", in: dir)
        let r = DiagnosticReports.scan(since: now.addingTimeInterval(-3600), directories: [dir.path])
        XCTAssertEqual(r.count, 5)
        XCTAssertEqual(r.filter { $0.kind == .crash }.count, 2)
        XCTAssertEqual(r.first { $0.kind == .crash }?.summary, "EXC_BAD_ACCESS / SIGSEGV")
        XCTAssertEqual(r.first { $0.process == "bar" }?.kind, .userFault)
        XCTAssertEqual(r.first { $0.process == "curl" }?.kind, .diskWrites)
        XCTAssertTrue(r.first { $0.process == "curl" }?.summary?.hasPrefix("8589.94 MB") ?? false)
        XCTAssertEqual(r.first { $0.kind == .jetsam }?.process, "System")
        let f = DiagnosticReports.findings(r, now: now)
        XCTAssertEqual(f.map(\.title), ["Foo crashed 2 times in the last 24 hours"])
        print("REAL", DiagnosticReports.scan(since: now.addingTimeInterval(-7 * 86_400)).prefix(6).map { "\($0.kind.rawValue): \($0.process) \($0.summary ?? "")" })
    }
}

/// Startup items (launch agents and daemons).
final class StartupItemTests: XCTestCase {
    /// Every startup item whose program exists gets a signature verdict, so the Startup page never shows a blank
    /// signer for a program it could have checked.
    func testSignersAndOrphans() {
        let items = Launchd.startupItems()
        print("STARTUP", items.count, "orphans", items.filter(\.orphaned).map(\.label), "unsigned", items.filter { $0.signer?.hasPrefix("Not signed") == true }.map(\.label))
        XCTAssertTrue(items.filter { $0.programExists == true }.allSatisfy { $0.signer != nil }, "every existing program gets a signature verdict")
    }
}

/// Call-stack evidence captured for hangs and hogs.
final class EvidenceTests: XCTestCase {
    /// Reduces a `/usr/bin/sample` call graph to one line: the heaviest main-thread path, leaf first, with the share of
    /// samples in it and a "waiting" label when the leaf is a blocking call such as a mutex wait.
    func testSummarizesHeaviestMainThreadPath() {
        let text = """
        Call graph:
            2622 Thread_1: Main Thread   DispatchQueue_1: com.apple.main-thread  (serial)
            + 2622 start  (in dyld) + 6992  [0x1]
            +   2622 main  (in Busy) + 20  [0x2]
            +     2600 -[Model recompute]  (in Busy) + 40  [0x3]
            +     ! 2590 -[Model sortItems:]  (in Busy) + 12  [0x4]
            +     ! : 2500 __psynch_mutexwait  (in libsystem_kernel.dylib) + 8  [0x5]
            +     ! : 90 objc_msgSend  (in libobjc.A.dylib) + 4  [0x6]
            +     22 -[Model other]  (in Busy) + 1  [0x7]
            2622 Thread_2
        Total number in stack (recursive counted multiple times):
        """
        let s = StackSummary.summarize(text)
        XCTAssertEqual(s, "Main thread waiting (95% of samples) in __psynch_mutexwait (libsystem_kernel.dylib) ← -[Model sortItems:] (Busy) ← -[Model recompute] (Busy)")
    }

    /// Captures evidence from a real child process (a same-user process can be sampled without root) and writes it to disk.
    func testRealCaptureOfAnotherProcess() throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["10"]
        try p.run(); defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        let id = UUID()
        let r = EvidenceStore.capture(pid: p.processIdentifier, name: "sleep", incident: id, seconds: 1)
        print("EVIDENCE", r?.1 as Any)
        XCTAssertNotNil(r)
        if let u = r?.0 { try? FileManager.default.removeItem(at: u) }
    }
}

/// Sleep log (`pmset -g log`) parsing.
final class SleepLogTests: XCTestCase {
    /// One clamshell sleep with two dark wakes, wake requests, the final lid-open wake and two overlapping assertions.
    /// Checks the session's plain-English reasons, battery use (90% → 85%), time asleep summed over the sleep spells,
    /// wake reason classification, wake requesters, and that overlapping assertion holds are merged, not double counted.
    func testParsesASessionWithDarkWakes() {
        let log = [
            "2026-11-16 00:10:00 -0600 Sleep               \tEntering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using BATT (Charge:90%) 600 secs  ",
            "2026-11-16 00:20:00 -0600 DarkWake            \tDarkWake from Deep Idle [CDNPB] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty E_RX_IP_PACKET ARPT/ Using BATT (Charge:89%) 30 secs",
            "2026-11-16 00:20:02 -0600 Wake Requests       \t[process=mDNSResponder request=Maintenance deltaSecs=7198 wakeAt=2026-11-16 02:20:00 info=\"upkeep wake\"] [process=dasd request=SleepService deltaSecs=999]",
            "2026-11-16 00:20:30 -0600 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using BATT (Charge:89%) 3000 secs",
            "2026-11-16 01:10:30 -0600 DarkWake            \tDarkWake from Deep Idle [CDNPB] : due to NUB.SPMISw3IRQ nub-spmi0.0x02 rtc/Maintenance Using BATT (Charge:88%) 10 secs",
            "2026-11-16 01:10:40 -0600 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using BATT (Charge:88%) 20000 secs",
            "2026-11-16 06:44:00 -0600 Wake                \tDarkWake to FullWake from Deep Idle [CDNVA] : due to EC.LidOpen/Lid Open Using BATT (Charge:85%)",
            "2026-11-16 07:00:00 -0600 Assertions          \tPID 883(Google Chrome) Released NoDisplaySleepAssertion \"Video Wake Lock\" 00:12:05 id:0x1 [System: x]",
            "2026-11-16 07:05:00 -0600 Assertions          \tPID 883(Google Chrome) Released NoDisplaySleepAssertion \"Video Wake Lock\" 00:10:00 id:0x2 [System: x]",
        ].joined(separator: "\n")
        let r = SleepLog.parse(log, since: .distantPast)
        XCTAssertEqual(r.sessions.count, 1)
        let s = r.sessions[0]
        XCTAssertEqual(s.why, "Lid closed")
        XCTAssertEqual(s.wokeBy, "Lid opened")
        XCTAssertEqual(s.darkWakes.count, 2)
        XCTAssertEqual(s.batteryUsed, 5)
        XCTAssertEqual(s.asleepSeconds, 23_600)
        XCTAssertEqual(r.darkWakeReasons.map(\.reason).sorted(), ["Network traffic arrived (Wi-Fi)", "Scheduled maintenance (network upkeep, Power Nap)"])
        XCTAssertEqual(r.wakeRequesters.map(\.process).sorted(), ["dasd", "mDNSResponder"])
        XCTAssertEqual(r.keptAwake.first?.process, "Google Chrome"); XCTAssertEqual(r.keptAwake.first?.seconds, 1025, "overlapping holds are merged: 06:47:55–07:05:00")
    }

    /// Prints a summary of this Mac's real log for manual review; no assertions, since every Mac's history differs.
    func testRealLog() {
        guard let r = SleepLog.read(days: 3) else { return }
        print("SLEEP sessions", r.sessions.count, "darkwakes", r.events.filter { $0.kind == .darkWake }.count,
              "reasons", r.darkWakeReasons.prefix(4).map { "\($0.reason) ×\($0.count)" }, "requesters", r.wakeRequesters.prefix(3).map(\.process),
              "awake", r.keptAwake.prefix(3).map { "\($0.process) \($0.seconds / 60)m" })
        if let s = r.sessions.first { print("LAST", s.start, "→", s.end, s.why, "woke by", s.wokeBy, "dark", s.darkWakes.count, "battery", s.batteryUsed as Any) }
    }
}
