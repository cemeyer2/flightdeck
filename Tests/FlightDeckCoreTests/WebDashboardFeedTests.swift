// Web dashboard: what it is fed while the privileged helper fills in other users' counters. The dashboard must serve
// no value that came from the helper, so these tests run a main Analyzer on the full samples (as the Engine does) and
// check that what the feed hands the dashboard carries none of the helper's processes, names or numbers.
import XCTest
@testable import FlightDeckCore

final class WebDashboardFeedTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_900_000_000)
    static let me: UInt32 = 501

    func proc(_ name: String, path: String, pid: Int32, cpu: Double, uid: UInt32 = me, source: ValueSource? = nil) -> ProcessSample {
        var p = BlackBoxTests.base.processes[0]
        p.identity = ProcessIdentity(pid: pid, startTime: 1); p.name = name; p.path = path; p.uid = uid
        p.cpu = cpu; p.memory = 100_000_000; p.threads = 4; p.energyTotal = nil; p.wakeups = 0
        p.diskReadBps = 0; p.diskWriteBps = 0; p.network = nil; p.powerAssertions = nil; p.notResponding = nil; p.gpu = nil
        p.restricted = source == .helper; p.source = source
        return p
    }
    /// Only the helper could read this one (another user's daemon).
    func secretd(cpu: Double) -> ProcessSample { proc("secretd", path: "/usr/libexec/secretd", pid: 900, cpu: cpu, uid: 0, source: .helper) }
    func safari(cpu: Double) -> ProcessSample { proc("Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", pid: 10, cpu: cpu) }
    /// Another user's Safari helper process in the same app group, measured by the helper.
    func helperSafari(cpu: Double) -> ProcessSample {
        proc("Safari Networking", path: "/Applications/Safari.app/Contents/MacOS/Safari Networking", pid: 11, cpu: cpu, uid: 0, source: .helper)
    }

    func snap(_ i: Int, cpu: Double = 10, _ procs: [ProcessSample]) -> Snapshot {
        var s = BlackBoxTests.base
        s.time = t0.addingTimeInterval(Double(i)); s.cpu.total = .value(cpu); s.processes = procs
        s.memory.pressureLevel = 1; s.memory.swapUsed = .value(0); s.power.thermalState = 0; s.power.battery = nil
        s.disk.readBps = .value(0); s.disk.writeBps = .value(0); s.network.inBps = .value(0); s.network.outBps = .value(0)
        s.disk.volumes = [VolumeInfo(name: "HD", path: "/", capacity: 1_000_000_000_000, available: 500_000_000_000, fileSystem: "apfs", isInternal: true)]
        s.drives = nil; s.wifi = nil; s.latency = nil; s.gpuDetail = nil
        return s
    }

    /// The Engine's sampling path in miniature: the main Analyzer and incident log see everything; the feed decides
    /// what the dashboard gets.
    final class Rig {
        let main = Analyzer(), mainLog = IncidentLog(url: nil), feed = WebDashboardFeed(ownUID: WebDashboardFeedTests.me)
        var lastMain: [Finding] = []
        @discardableResult
        func step(_ s: Snapshot, enabled: Bool = true, others: [Finding] = []) -> WebDashboardData? {
            let analyzed = main.ingest(s)
            lastMain = analyzed + others
            mainLog.update(lastMain, at: s.time)
            return feed.ingest(s, enabled: enabled, analyzed: analyzed, others: others)
        }
    }

    func text(_ fs: [Finding]) -> String { fs.map { "\($0.title) \($0.detail ?? "")" }.joined(separator: "\n") }

    func testHelperInactiveReusesMainSetWithoutAnalysing() throws {
        let r = Rig()
        let extra = Finding(id: "backup-old", severity: .info, icon: "clock", title: "No backup", detail: nil, since: t0, destination: nil)
        var out: WebDashboardData?
        for i in 0..<40 { out = r.step(snap(i, [safari(cpu: 120)]), others: [extra]) }
        let d = try XCTUnwrap(out)
        XCTAssertEqual(d.findings, r.lastMain, "no helper values: the main findings are already clean")
        XCTAssertTrue(d.findings.contains { $0.id == "cpu:/Applications/Safari.app" })
        XCTAssertFalse(r.feed.isAnalyzing, "no second analysis while the helper isn't contributing")
        XCTAssertEqual(d.incidents.map(\.key), r.mainLog.incidents.map(\.key))
    }

    func testDashboardOffDoesNoWorkAndKeepsNothing() {
        let r = Rig()
        for i in 0..<5 { XCTAssertNil(r.step(snap(i, [safari(cpu: 1), secretd(cpu: 300)]), enabled: false)) }
        XCTAssertFalse(r.feed.isAnalyzing)
        r.step(snap(5, [safari(cpu: 1), secretd(cpu: 300)]))
        XCTAssertTrue(r.feed.isAnalyzing)
        XCTAssertNil(r.step(snap(6, [safari(cpu: 1), secretd(cpu: 300)]), enabled: false))
        XCTAssertFalse(r.feed.isAnalyzing, "turning the dashboard off discards its analyzer")
    }

    func testHelperMeasuredProcessesAbsentAndOtherUsersThreadsZeroed() throws {
        let r = Rig()
        var other = proc("cupsd", path: "/usr/sbin/cupsd", pid: 50, cpu: 1, uid: 0, source: .app); other.threads = 12
        let d = try XCTUnwrap(r.step(snap(0, [safari(cpu: 5), secretd(cpu: 300), helperSafari(cpu: 60), other])))
        XCTAssertEqual(d.snapshot.processes.map(\.pid), [10, 50])
        XCTAssertEqual(d.snapshot.processes.map(\.threads), [4, 0], "another user's thread count can only have come from the helper")
    }

    func testSaturationDoesNotNameHelperOnlyBiggestUser() throws {
        let r = Rig()
        var out: WebDashboardData?
        for i in 0..<40 { out = r.step(snap(i, cpu: 97, [safari(cpu: 20), secretd(cpu: 70)])) }
        XCTAssertTrue(text(r.lastMain).contains("Biggest user: secretd"), "the main analyzer does name it")
        let d = try XCTUnwrap(out)
        let sat = try XCTUnwrap(d.findings.first { $0.id == "cpu-saturated" }, "the machine-wide finding itself is the app's own reading")
        XCTAssertEqual(sat.detail, "Biggest user: Safari at 20%.")
        XCTAssertFalse(text(d.findings).contains("secretd"))
    }

    func testMixedGroupCPUExcludesHelperProcesses() throws {
        let r = Rig()
        var out: WebDashboardData?
        for i in 0..<40 { out = r.step(snap(i, [safari(cpu: 90), helperSafari(cpu: 60)])) }
        XCTAssertTrue(text(r.lastMain).contains("Safari (2 processes) is using 150% CPU"))
        let d = try XCTUnwrap(out)
        let f = try XCTUnwrap(d.findings.first { $0.id == "cpu:/Applications/Safari.app" })
        XCTAssertEqual(f.title, "Safari is using 90% CPU")
        XCTAssertEqual(f.pids, [10])
        let doc = WebDashboardState.build(WebDashboardInputs(
            snapshot: d.snapshot, findings: d.findings, incidents: d.incidents, displayName: "", modelName: "Mac", hardwareModel: "",
            macOS: "26", appVersion: "1", uptime: nil, paused: false, intervalS: 1, redaction: FleetRedaction(names: [])))
        XCTAssertEqual(doc.topApps.first { $0.name == "Safari" }?.cpuPercent, 90)
        XCTAssertEqual(doc.topApps.first { $0.name == "Safari" }?.count, 1)
    }

    func testIncidentsFromHelperOnlyDataAbsent() throws {
        let r = Rig()
        var out: WebDashboardData?
        for i in 0..<60 { out = r.step(snap(i, [safari(cpu: 1), secretd(cpu: 300)])) }
        XCTAssertTrue(r.mainLog.incidents.contains { $0.title.contains("secretd") }, "the main log does record it")
        let d = try XCTUnwrap(out)
        XCTAssertFalse(d.incidents.contains { $0.key.contains("secretd") || $0.title.contains("secretd") })
    }

    /// The main Analyzer keeps smoothed helper values (CPU over ~20 s, memory trends over 30 min) after the helper goes
    /// away, so the dashboard keeps its own analysis for a while instead of switching straight back.
    func testHelperDisconnectLeavesNoHelperDerivedFinding() throws {
        let r = Rig()
        for i in 0..<40 { r.step(snap(i, [safari(cpu: 90), helperSafari(cpu: 60), secretd(cpu: 300)])) }
        // The helper drops out: the same processes are now the app's own rows, unreadable (zero CPU).
        var gone = secretd(cpu: 0); gone.source = .app
        var goneSafari = helperSafari(cpu: 0); goneSafari.source = .app
        let d = try XCTUnwrap(r.step(snap(40, [safari(cpu: 90), goneSafari, gone])))
        XCTAssertTrue(text(r.lastMain).contains("secretd is using"), "the main analyzer still carries the helper's CPU")
        XCTAssertFalse(text(d.findings).contains("secretd"))
        XCTAssertEqual(d.findings.first { $0.id == "cpu:/Applications/Safari.app" }?.title, "Safari (2 processes) is using 90% CPU")
        XCTAssertTrue(r.feed.isAnalyzing)
        // Once the main analyzer has had time to forget, the main set is reused again.
        let later = Int(WebDashboardFeed.holdDown) + 40
        let e = try XCTUnwrap(r.step(snap(later, [safari(cpu: 90), goneSafari, gone])))
        XCTAssertFalse(r.feed.isAnalyzing)
        XCTAssertEqual(e.findings, r.lastMain)
    }

    func testHelperSeenWhileDashboardOffStillHoldsDown() {
        let r = Rig()
        for i in 0..<40 { r.step(snap(i, [safari(cpu: 1), secretd(cpu: 300)]), enabled: false) }
        var gone = secretd(cpu: 0); gone.source = .app
        let d = r.step(snap(40, [safari(cpu: 1), gone]))
        XCTAssertTrue(text(r.lastMain).contains("secretd is using"))
        XCTAssertFalse(text(d?.findings ?? []).contains("secretd"), "the main analyzer is tainted even if the dashboard was off")
    }

    // MARK: What Changed

    func event(_ name: String, _ item: InventoryItem) -> ChangeEvent {
        ChangeEvent(id: "added:" + item.id, detected: t0, estimated: nil, kind: .added, item: item, previous: nil,
                    summary: "Added \(name)", reasons: ["new"], notable: true)
    }
    func deviceProfile(_ name: String) -> InventoryItem {
        InventoryItem(category: .profile, key: "profile:" + name, name: name, scope: ChangeReaders.deviceScope)
    }
    func backgroundItem(_ name: String) -> InventoryItem {
        InventoryItem(category: .launchItem, key: ChangeReaders.backgroundKeyPrefix + name, name: name, scope: "Login Items (app)")
    }
    func agent(_ name: String) -> InventoryItem { InventoryItem(category: .launchItem, key: "agent:" + name, name: name) }

    /// Mac-wide profiles and Login Items background records are read by the helper, so changes to them stay off the
    /// dashboard, on their own and when they would be named in a batch finding.
    func testChangesReadByHelperStayOffDashboard() {
        let one = [event("SecretCorp MDM", deviceProfile("SecretCorp MDM")), event("Updater", agent("Updater"))]
        XCTAssertEqual(ChangeFindings.findings(one).count, 2)
        XCTAssertEqual(ChangeFindings.dashboardFindings(one).map(\.title), ["Added Updater"])
        let many = [event("SecretCorp MDM", deviceProfile("SecretCorp MDM")), event("hidden-bg", backgroundItem("hidden-bg"))]
            + (0..<4).map { event("Agent\($0)", agent("Agent\($0)")) }
        XCTAssertTrue(text(ChangeFindings.findings(many)).contains("6 notable changes"))
        let d = text(ChangeFindings.dashboardFindings(many))
        XCTAssertTrue(d.contains("4 notable changes"))
        XCTAssertFalse(d.contains("SecretCorp") || d.contains("hidden-bg"))
        let w = ChangeWatch()
        w.add(ChangeFindings.findings(one), dashboard: ChangeFindings.dashboardFindings(one), at: t0)
        XCTAssertEqual(w.findings(now: t0).count, 2)
        XCTAssertEqual(w.dashboardFindings(now: t0).map(\.title), ["Added Updater"])
        XCTAssertTrue(w.dashboardFindings(now: t0.addingTimeInterval(ChangeFindings.linger + 1)).isEmpty)
    }
}
