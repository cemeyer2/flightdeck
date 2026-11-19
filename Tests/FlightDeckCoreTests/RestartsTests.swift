// Tests for Restarts & Crashes: shutdown-cause lines and codes, panic reports in both formats, boot classification,
// boot timing, the boot store and finding de-duplication. Samples are synthetic, modelled on real output (the log's
// ndjson, .ips 210 and the old .panic text); the live smoke test skips where the sources aren't readable (CI VMs).
import XCTest
@testable import FlightDeckCore

final class ShutdownCauseTests: XCTestCase {
    func testCauseLines() {
        XCTAssertEqual(ShutdownCauseLog.code(in: "Previous shutdown cause: 5"), 5)
        XCTAssertEqual(ShutdownCauseLog.code(in: "AppleSMC: Previous Shutdown Cause: -128"), -128)
        XCTAssertEqual(ShutdownCauseLog.code(in: "Previous shutdown cause:-3"), -3)
        XCTAssertNil(ShutdownCauseLog.code(in: "Shutdown cause unknown"))
        let nd = """
        {"timestamp":"2026-11-10 08:00:05.123456-0600","eventType":"logEvent","messageType":"Default","eventMessage":"Previous shutdown cause: -61","processImagePath":"/kernel"}
        {"timestamp":"2026-11-10 08:00:06.000000-0600","eventType":"logEvent","messageType":"Default","eventMessage":"something else"}
        {"count":1,"finished":1}
        """
        let e = ShutdownCauseLog.parse(ndjson: nd)
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e.first?.code, -61)
        XCTAssertEqual(e.first?.logged, LogParser.parseTimestamp("2026-11-10 08:00:05.123456-0600"))
    }

    func testCodeMapping() {
        XCTAssertEqual(ShutdownCause.of(5).concern, .normal)
        XCTAssertFalse(ShutdownCause.of(5).unexpected)
        XCTAssertEqual(ShutdownCause.of(3).concern, .notable)
        XCTAssertEqual(ShutdownCause.of(0).title, "Power lost")
        for c in [-3, -60, -61, -62, -71, -74] {
            XCTAssertEqual(ShutdownCause.of(c).concern, .concern, "\(c)")
            XCTAssertEqual(ShutdownCause.of(c).certainty, .established, "\(c)")
        }
        XCTAssertEqual(ShutdownCause.of(-128).certainty, .reported)
        let unknown = ShutdownCause.of(-999)
        XCTAssertEqual(unknown.certainty, .undocumented)
        XCTAssertEqual(unknown.concern, .unknown)
        XCTAssertTrue(unknown.title.contains("-999"))
    }
}

final class PanicReportTests: XCTestCase {
    static let ips = #"""
    {"bug_type":"210","timestamp":"2026-11-12 09:14:02.00 -0600","os_version":"macOS 26.1 (25B78)","incident_id":"X"}
    {
      "build" : "macOS 26.1 (25B78)",
      "product" : "Mac15,6",
      "date" : "2026-11-12 09:11:28.92 -0600",
      "panicString" : "panic(cpu 4 caller 0xfffffe0029f4b8e0): userspace watchdog timeout: no successful checkins from WindowServer (2 induced crashes) in 120 seconds\nservice: WindowServer, total successful checkins since wake (1460 seconds ago): 146\nPanicked task 0xfffffe1b3a8d8678: 191 pages, 8 threads: pid 104: watchdogd\nKernel Extensions in backtrace:\n  com.apple.driver.AppleARMWatchdogTimer(1.0)[ABC]@0xfffffe0029000000->0xfffffe0029003fff\n",
      "panicFlags" : "0x902"
    }
    """#

    func testIPSWatchdog() throws {
        let r = try XCTUnwrap(PanicReports.parse(Self.ips, path: "/x/panic-full-2026-11-12.ips", modified: Date()))
        XCTAssertEqual(r.culprit, .userspaceWatchdog)
        XCTAssertEqual(r.culpritName, "WindowServer")
        XCTAssertEqual(r.task, "watchdogd")
        XCTAssertTrue(r.timeIsPanic)
        XCTAssertEqual(r.osVersion, "macOS 26.1 (25B78)")
        XCTAssertTrue(r.headline.hasPrefix("userspace watchdog timeout"))
        XCTAssertEqual(r.kexts, ["com.apple.driver.AppleARMWatchdogTimer"])
        XCTAssertTrue(r.explanation.contains("WindowServer"))
    }

    func testIPSThirdPartyKextAndTruncatedBody() throws {
        let body = #"{"bug_type":"210","timestamp":"2026-11-13 10:00:00.00 -0600"}"# + "\n" + #"{ "panicString" : "panic(cpu 0 caller 0xfff): Kernel data abort. at pc 0x1\nPanicked task 0xff: 0 pages, 1 threads: pid 0: kernel_task\nKernel Extensions in backtrace:\n  com.example.driver(2.1)[UUID]@0x1->0x2\n    dependency: com.apple.iokit.IOPCIFamily(2.9)[U]@0x3->0x4\n", "#
        let r = try XCTUnwrap(PanicReports.parse(body, path: "/x/a.panic", modified: Date()))
        XCTAssertEqual(r.culprit, .thirdPartyDriver)
        XCTAssertEqual(r.culpritName, "com.example.driver")
        XCTAssertEqual(r.kexts, ["com.example.driver"])   // dependency lines aren't suspects
        XCTAssertFalse(r.timeIsPanic)                      // only the header's write time
        XCTAssertTrue(r.explanation.hasPrefix("Kernel panic in com.example.driver"))
    }

    func testOldTextPanic() throws {
        let text = """
        Anonymous UUID:       1234
        Sat Jan  4 10:02:11 2020

        *** Panic Report ***
        panic(cpu 2 caller 0xffffff801a2b3c4d): "watchdog timeout: no checkins from watchdogd in 90 seconds (0 total checkins since monitoring last enabled)"@/BuildRoot/Library/Caches/watchdog.c:211
        Backtrace (CPU 2), Frame : Return Address
        BSD process name corresponding to current thread: kernel_task

        Mac OS version:
        19C57
        """
        let r = try XCTUnwrap(PanicReports.parse(text, path: "/x/Kernel-2020.panic", modified: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(r.culprit, .watchdog)
        XCTAssertEqual(r.task, "kernel_task")
        XCTAssertEqual(r.osVersion, "19C57")
        XCTAssertTrue(r.timeIsPanic)
        XCTAssertTrue(r.headline.hasPrefix("watchdog timeout: no checkins from watchdogd"), r.headline)
        XCTAssertNil(PanicReports.parse("not a panic", path: "/x", modified: Date()))
    }
}

final class BootHistoryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    func at(_ h: Double) -> Date { t0.addingTimeInterval(h * 3600) }

    func testClassification() {
        var s = BootSources()
        s.boots = [at(0), at(24), at(48), at(72), at(96), at(96).addingTimeInterval(0.4)]   // last two are the same boot
        s.logdFlushes = [at(-1), at(23.9)]            // marker before boots 0 and 1
        s.causes = [ShutdownCauseEntry(logged: at(72).addingTimeInterval(20), code: -3)]
        let panic = PanicReport(path: "/p.ips", time: at(47), timeIsPanic: true, headline: "x", task: nil, kexts: [], osVersion: nil, culprit: .watchdog, culpritName: nil)
        s.panics = [panic]
        let e = BootHistory.classify(s)
        XCTAssertEqual(e.count, 5)
        let byBoot = Dictionary(uniqueKeysWithValues: e.map { ($0.boot, $0.previous) })
        XCTAssertEqual(byBoot[at(0)]?.kind, .clean)         // oldest boot, but a marker just before it
        XCTAssertEqual(byBoot[at(24)]?.kind, .clean)        // orderly marker
        XCTAssertEqual(byBoot[at(48)]?.kind, .panic)        // panic during the session before
        XCTAssertEqual(byBoot[at(72)]?.kind, .unexpected)   // thermal code
        XCTAssertEqual(byBoot[at(72)]?.cause?.code, -3)
        XCTAssertEqual(byBoot[at(96)]?.kind, .unexpected)   // covered by the shutdown log, no marker
        XCTAssertEqual(byBoot[at(96)]?.inferred, true)
        XCTAssertEqual(e.first?.boot, at(96))               // newest first
    }

    func testPanicWrittenAtBootBelongsToThatBoot() {
        // A report with only its write time, a few minutes after a boot, describes the shutdown before that boot.
        let p = PanicReport(path: "/p", time: at(24).addingTimeInterval(120), timeIsPanic: false, headline: "", task: nil, kexts: [], osVersion: nil, culprit: .unknown, culpritName: nil)
        XCTAssertEqual(BootHistory.owner(of: p.time, atBoot: true, boots: [at(0), at(24)]), at(24))
        XCTAssertEqual(BootHistory.owner(of: at(10), atBoot: false, boots: [at(0), at(24)]), at(24))
    }

    func testNormalCodeWinsOverMissingMarker() {
        let v = BootHistory.decide(panic: nil, cause: ShutdownCauseEntry(logged: t0, code: 5), marker: nil, markerSource: "", power: nil, covered: true, hasPrevious: true)
        XCTAssertEqual(v.kind, .clean)
        let u = BootHistory.decide(panic: nil, cause: ShutdownCauseEntry(logged: t0, code: 77), marker: t0, markerSource: "m", power: nil, covered: true, hasPrevious: true)
        XCTAssertEqual(u.kind, .clean); XCTAssertTrue(u.inferred)
        // No evidence: unknown, whether or not there was an earlier boot; never "unexpected" without coverage.
        XCTAssertEqual(BootHistory.decide(panic: nil, cause: nil, marker: nil, markerSource: "", power: nil, covered: false, hasPrevious: false).kind, .unknown)
        XCTAssertEqual(BootHistory.decide(panic: nil, cause: nil, marker: nil, markerSource: "", power: nil, covered: false, hasPrevious: true).kind, .unknown)
    }

    func testFlushAndPowerLogParsing() {
        let f = BootSourcesReader.parseFlushes("4.2s elapsed\nSIGTERM: [1793284560] All buffers flushed\nnoise\nSIGTERM: [1790707812] All buffers flushed\n")
        XCTAssertEqual(f.map { Int($0.timeIntervalSince1970) }, [1793284560, 1790707812])
        let log = """
        2026-11-12 16:02:15 -0600 Shutdown            \tShutdown requested by user
        2026-11-12 16:05:15 -0600 Start               \tSystem started
        2026-11-13 08:00:00 -0600 Wake                \tWake from Hibernate [CDNVA] : due to PowerButton Using AC
        2026-11-13 09:00:00 -0600 Wake                \tDarkWake to FullWake from Deep Idle : due to UserActivity Assertion
        2026-11-13 09:00:00 -0600 Sleep               \tEntering Sleep state
        """
        let p = BootSourcesReader.parsePowerLog(log)
        XCTAssertEqual(p.map(\.kind), [.shutdown, .start, .hibernateWake])
    }
}

final class BootTimingTests: XCTestCase {
    func testPhases() {
        let boot = Date(timeIntervalSince1970: 1_793_285_065)
        func p(_ name: String, _ path: String, _ s: Double, uid: UInt32 = 501, ppid: Int32 = 1, cpu: Double = 1) -> BootProcess {
            BootProcess(name: name, path: path, start: boot.addingTimeInterval(s), uid: uid, ppid: ppid, cpuTime: cpu)
        }
        let procs = [
            p("loginwindow", "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow", 7),
            p("Dock", "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", 56),
            p("Finder", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", 56.5),
            p("SystemUIServer", "/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer", 56),
            p("Slack", "/Applications/Slack.app/Contents/MacOS/Slack", 70, cpu: 40),
            p("Slack Helper", "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper", 72, ppid: 900, cpu: 10),
            p("agent", "/opt/vendor/agent", 60, cpu: 3),
            p("rootd", "/Library/PrivilegedHelperTools/rootd", 62, uid: 0, cpu: 2),     // root, not a known daemon: skipped
            p("late", "/Applications/Late.app/Contents/MacOS/Late", 26 + 400),           // after the window
        ]
        let t = BootTimer.compute(boot: boot, login: boot.addingTimeInterval(26), processes: procs, uid: 501, agents: ["/opt/vendor/agent"])
        XCTAssertEqual(t.toLoginWindow, 7)
        XCTAssertEqual(t.atLoginWindow, 19)
        XCTAssertEqual(t.loginToDesktop ?? 0, 30.5, accuracy: 0.01)
        XCTAssertEqual(t.bootToDesktop ?? 0, 56.5, accuracy: 0.01)
        XCTAssertEqual(t.items.map(\.name), ["agent", "Slack"])
        XCTAssertEqual(t.items.first?.kind, "Launch agent")
        XCTAssertEqual(t.items.last?.kind, "App")
        XCTAssertEqual(t.items.last?.cpuSeconds, 50)                  // helpers grouped into their app
        XCTAssertEqual(t.itemsPhase ?? 0, 72 - 56.5, accuracy: 0.01)    // desktop → last item started
        let noLogin = BootTimer.compute(boot: boot, login: nil, processes: procs, uid: 501)
        XCTAssertNil(noLogin.loginToDesktop); XCTAssertEqual(noLogin.toLoginWindow, 7)
    }
}

final class RestartFindingTests: XCTestCase {
    func testOneShot() {
        let boot = Date(timeIntervalSince1970: 1_790_000_000)
        let v = BootHistory.decide(panic: nil, cause: ShutdownCauseEntry(logged: boot, code: -74), marker: nil, markerSource: "", power: nil, covered: false, hasPrevious: true)
        let e = BootEvent(boot: boot, previousBoot: boot.addingTimeInterval(-86_400), previous: v, login: nil)
        let first = RestartFindings.evaluate(events: [e], panics: [], announced: [], since: boot.addingTimeInterval(-60))
        XCTAssertEqual(first.findings.count, 1)
        XCTAssertEqual(first.findings.first?.severity, .caution)
        XCTAssertEqual(first.findings.first?.destination, RestartFindings.destination)
        let again = RestartFindings.evaluate(events: [e], panics: [], announced: first.keys, since: boot.addingTimeInterval(-60))
        XCTAssertTrue(again.findings.isEmpty)                    // never repeated
        let old = RestartFindings.evaluate(events: [e], panics: [], announced: [], since: boot.addingTimeInterval(60))
        XCTAssertTrue(old.findings.isEmpty)                      // before the last check

        // A panic tied to a boot is announced once, through the boot; the same report isn't announced on its own.
        let p = PanicReport(path: "/a/panic.ips", time: boot.addingTimeInterval(-600), timeIsPanic: true, headline: "", task: nil, kexts: [], osVersion: nil, culprit: .watchdog, culpritName: nil)
        let pv = BootHistory.decide(panic: p, cause: nil, marker: nil, markerSource: "", power: nil, covered: true, hasPrevious: true)
        let pe = BootEvent(boot: boot, previousBoot: nil, previous: pv, login: nil)
        let r = RestartFindings.evaluate(events: [pe], panics: [p], announced: [], since: boot.addingTimeInterval(-3600))
        XCTAssertEqual(r.findings.count, 1)
        XCTAssertEqual(r.findings.first?.severity, .warning)
        XCTAssertTrue(r.keys.contains(RestartFindings.key(p)))
        XCTAssertTrue(RestartFindings.evaluate(events: [], panics: [p], announced: r.keys, since: .distantPast).findings.isEmpty)
    }

    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let s = BootStore(dir: dir)
        s.update(now.addingTimeInterval(-3600)) { $0.cause = ShutdownCauseEntry(logged: now, code: 5); $0.causeQueried = true }
        s.update(now.addingTimeInterval(-3600.3)) { $0.timing = BootTiming(boot: $0.boot) }   // same boot within a minute
        s.update(now.addingTimeInterval(-100 * 86_400)) { _ in }                              // past retention
        s.markAnnounced(["boot:1"], checked: now)
        s.save(now: now)
        let r = BootStore(dir: dir)
        XCTAssertEqual(r.records.count, 1)
        XCTAssertEqual(r.records.first?.cause?.code, 5)
        XCTAssertNotNil(r.records.first?.timing)
        XCTAssertEqual(r.announced, ["boot:1"])
        XCTAssertEqual(r.lastCheck.map { Int($0.timeIntervalSince1970) }, Int(now.timeIntervalSince1970))
    }

    /// Reads this Mac's real sources (no unified-log query). Skips where wtmp has no boots (CI VMs may have none).
    func testLiveSourcesSmoke() throws {
        let w = BootSourcesReader.wtmp()
        guard w.contains(where: { $0.kind == .boot }) else { throw XCTSkip("no boot records in wtmp here") }
        let r = RestartsCollector.collect(store: BootStore(dir: nil), queryLog: .none)
        XCTAssertFalse(r.events.isEmpty)
        XCTAssertNotNil(r.current)
        if ProcessInfo.processInfo.environment["FD_PRINT_RESTARTS"] != nil {
            for e in r.events { print(e.boot, e.previous.kind.rawValue, e.previous.title, e.previous.evidence, e.login.map { $0.timeIntervalSince(e.boot) } ?? -1) }
            if let t = r.current { print(t.toLoginWindow ?? -1, t.atLoginWindow ?? -1, t.loginToDesktop ?? -1, t.itemsPhase ?? -1, t.items.map(\.name), t.busiest.map(\.name)) }
            print(r.limits.joined(separator: "\n"), r.ssd.map { "\($0)" } ?? "no ssd", r.hangs.count)
        }
    }
}

final class RestartsMCPTests: XCTestCase {
    func testOutput() throws {
        let now = Date()
        let boot = now.addingTimeInterval(-3600)
        let p = try XCTUnwrap(PanicReports.parse(PanicReportTests.ips, path: "/x/panic.ips", modified: now))
        var r = RestartsReport()
        let v = BootHistory.decide(panic: p, cause: nil, marker: nil, markerSource: "", power: nil, covered: true, hasPrevious: true)
        r.events = [BootEvent(boot: boot, previousBoot: boot.addingTimeInterval(-86_400), previous: v, login: boot.addingTimeInterval(25))]
        let j = MCPTools.restartsJSON(r, days: 30, now: now)
        XCTAssertTrue(j["summary"]?.string?.contains("1 after an unexpected shutdown or panic") == true)
        XCTAssertEqual(j["boots"]?.array?.first?["previous_session_ended"]?["kind"]?.string, "kernel panic")
        XCTAssertEqual(j["boots"]?.array?.first?["boot_to_login"]?.string, "25 s")
        let pj = MCPTools.panicsJSON([p])
        XCTAssertEqual(pj["panics"]?.array?.first?["culprit_name"]?.string, "WindowServer")
        XCTAssertTrue(MCPTools.panicsJSON([])["summary"]?.string?.hasPrefix("No kernel panic") == true)
    }
}
