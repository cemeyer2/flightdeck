import XCTest
@testable import FlightDeckHelperProtocol
@testable import FlightDeckHelperCore

final class HelperServiceTests: XCTestCase {
    // MARK: Runner

    func testRunnerCapsOutput() {
        XCTAssertEqual(BoundedToolRunner(maxBytes: 1024).run(path: "/usr/bin/yes", arguments: []), .tooLarge)
    }

    func testRunnerTimesOut() {
        let start = Date()
        XCTAssertEqual(BoundedToolRunner(timeout: 0.3).run(path: "/bin/sleep", arguments: ["5"]), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testRunnerReturnsOutput() {
        XCTAssertEqual(BoundedToolRunner().run(path: "/bin/echo", arguments: ["hi"]), .output("hi\n"))
        XCTAssertEqual(BoundedToolRunner().run(path: "/usr/bin/false", arguments: []), .failed)
        XCTAssertEqual(BoundedToolRunner().run(path: "/bin/sh", arguments: ["-c", "echo partial; exit 1"]), .output("partial\n"))
        XCTAssertEqual(BoundedToolRunner().run(path: "/nonexistent/tool", arguments: []), .failed)
    }

    func testRunnerToolArgumentsAreConstants() {
        XCTAssertEqual(HelperTool.sample(pid: 42, seconds: 3).arguments, ["42", "3", "-mayDie", "-file", "/dev/stdout"])
        XCTAssertEqual(HelperTool.footprint(pid: 42).arguments, ["--swapped", "-f", "bytes", "42"])
        let all: [HelperTool] = [.netstatTCP, .netstatUDP, .lsofListening, .lsofInternet, .tmutilSnapshots, .profilesDevice,
                                 .sfltoolDumpbtm, .sample(pid: 1, seconds: 1), .footprint(pid: 1)]
        for t in all { XCTAssertTrue(t.path.hasPrefix("/usr/") || t.path.hasPrefix("/bin/"), t.path) }
    }

    // MARK: Service

    let form = Data(repeating: 0xAB, count: 32)
    let pid500 = HelperProcessID(pid: 500, startTime: 111)
    var authority = FakeAuthority()
    var processes = FakeProcessReader()
    var runner = FakeRunner()
    var settings = MemorySettings()
    var now = Date(timeIntervalSince1970: 10_000)
    var isEligible = true
    var present = true
    var right = true
    let app = HelperCaller(connection: 1, uid: 501)
    let standalone = HelperCaller(connection: 2, uid: 501)

    func makeService() -> HelperService {
        authority.validForms = [form]
        processes.identities[500] = pid500
        processes.names[500] = "Safari"
        processes.usage[500] = HelperRusage(cpuNs: 5, diskRead: 1, diskWritten: 2, energyNJ: 3, idleWakeups: 4, physFootprint: 9, threads: 7)
        return HelperService(authority: authority, registry: UnlockRegistry(clock: { [unowned self] in self.now }), runner: runner,
                             processes: processes, settings: settings,
                             eligible: { [unowned self] in self.isEligible }, bundlePresent: { [unowned self] in self.present },
                             rightInPlace: { [unowned self] in self.right }, clock: { [unowned self] in self.now })
    }

    func send(_ s: HelperService, _ r: HelperRequest, auth: Data? = nil, from c: HelperCaller? = nil) -> HelperResponse {
        s.handle(HelperEnvelope(request: r, authorization: auth), from: c ?? app)
    }

    func greeted(_ callers: HelperCaller...) -> HelperService {
        let s = makeService()
        for c in callers.isEmpty ? [app] : callers { _ = send(s, .hello(version: HelperIDs.protocolVersion), from: c) }
        return s
    }

    func code(_ r: HelperResponse) -> HelperRefusal.Code? {
        if case .refused(let x) = r { return x.code }
        return nil
    }

    func testHelloRequiredFirst() {
        XCTAssertEqual(code(send(makeService(), .status)), .helloRequired)
    }

    func testVersionMismatch() {
        let s = makeService()
        XCTAssertEqual(code(send(s, .hello(version: 2))), .versionMismatch)
        XCTAssertEqual(code(send(s, .status)), .helloRequired)
    }

    func testHelloReportsRight() {
        right = false
        guard case .hello(let h) = send(makeService(), .hello(version: 1)) else { return XCTFail() }
        XCTAssertFalse(h.rightInPlace)
        XCTAssertTrue(h.eligible)
    }

    func testNotEligibleRefusesEverything() {
        isEligible = false
        let s = makeService()
        XCTAssertEqual(code(send(s, .hello(version: 1))), .notEligible)
        XCTAssertEqual(code(send(s, .processRusage(ids: [pid500]), auth: form)), .notEligible)
    }

    func testBundleMissingRefuses() {
        present = false
        XCTAssertEqual(code(send(makeService(), .hello(version: 1))), .bundleMissing)
    }

    func testCountersNeedAuthorization() {
        let s = greeted()
        XCTAssertEqual(code(send(s, .processRusage(ids: [pid500]))), .notAuthorized)
        XCTAssertEqual(code(send(s, .processRusage(ids: [pid500]), auth: Data(repeating: 1, count: 16))), .notAuthorized)
        XCTAssertEqual(code(send(s, .processRusage(ids: [pid500]), auth: Data(repeating: 1, count: 32))), .notAuthorized)
    }

    func testCountersWithValidForm() {
        let s = greeted()
        guard case .rusage(let e) = send(s, .processRusage(ids: [pid500]), auth: form) else { return XCTFail() }
        XCTAssertEqual(e, [HelperRusageEntry(id: pid500, rusage: processes.usage[500]!)])
    }

    func testStandaloneGetsCountersWhileHolderAlive() {
        let s = greeted(app, standalone)
        _ = send(s, .status, auth: form)
        guard case .rusage = send(s, .processRusage(ids: [pid500]), from: standalone) else { return XCTFail() }
        s.connectionClosed(1)
        XCTAssertEqual(code(send(s, .processRusage(ids: [pid500]), from: standalone)), .notAuthorized)
    }

    func testStandaloneNeverGetsContents() {
        settings.agentContents = true
        let s = greeted(app, standalone)
        _ = send(s, .status, auth: form)
        XCTAssertEqual(code(send(s, .processDetails(id: pid500, parts: [.args]), from: standalone)), .notHolder)
        XCTAssertEqual(code(send(s, .setAgentContents(false), from: standalone)), .notHolder)
    }

    func testLockEndsAccess() {
        let s = greeted()
        guard case .rusage = send(s, .processRusage(ids: [pid500]), auth: form) else { return XCTFail() }
        XCTAssertEqual(send(s, .lock), .ok)
        XCTAssertEqual(code(send(s, .processRusage(ids: [pid500]))), .notAuthorized)
    }

    func testStatusReportsUnlock() {
        let s = greeted(app, standalone)
        XCTAssertEqual(send(s, .status, auth: form), .status(HelperServiceStatus(unlocked: true, holderAlive: true, agentContents: false)))
        XCTAssertEqual(send(s, .status, from: standalone), .status(HelperServiceStatus(unlocked: false, holderAlive: true, agentContents: false)))
    }

    func testProcessChangedBetweenChecksIsRefused() {
        let s = greeted()
        processes.identitySequence = [pid500, HelperProcessID(pid: 500, startTime: 999)]
        let r = send(s, .processDetails(id: pid500, parts: [.args, .env]), auth: form)
        XCTAssertEqual(code(r), .processChanged)
        if case .contents = r { XCTFail("contents of a recycled PID were returned") }
    }

    func testProcessChangedBeforeReadIsRefused() {
        let s = greeted()
        processes.identities[500] = HelperProcessID(pid: 500, startTime: 999)
        XCTAssertEqual(code(send(s, .processDetails(id: pid500, parts: [.args]), auth: form)), .processChanged)
        XCTAssertEqual(code(send(s, .memoryFootprint(id: pid500), auth: form)), .processChanged)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testRusageOmitsRecycled() {
        let s = greeted()
        let other = HelperProcessID(pid: 600, startTime: 222)
        processes.identities[600] = HelperProcessID(pid: 600, startTime: 333)
        processes.usage[600] = processes.usage[500]
        guard case .rusage(let e) = send(s, .processRusage(ids: [pid500, other]), auth: form) else { return XCTFail() }
        XCTAssertEqual(e.map(\.id), [pid500])
    }

    func testCriticalProcessRefused() {
        let s = greeted()
        processes.names[500] = "WindowServer"
        let r = send(s, .sampleStacks(id: pid500, seconds: 2), auth: form)
        XCTAssertEqual(code(r), .criticalProcess)
        if case .refused(let x) = r { XCTAssertTrue(x.message.contains("never samples WindowServer")) }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testRateLimit() {
        let s = greeted()
        guard case .toolText = send(s, .sampleStacks(id: pid500, seconds: 2), auth: form) else { return XCTFail() }
        now = now.addingTimeInterval(1)
        XCTAssertEqual(code(send(s, .sampleStacks(id: pid500, seconds: 2), auth: form)), .rateLimited)
        now = now.addingTimeInterval(1.1)
        guard case .toolText = send(s, .sampleStacks(id: pid500, seconds: 2), auth: form) else { return XCTFail() }
    }

    func testOutputTooLarge() {
        let s = greeted()
        runner.fallback = .tooLarge
        XCTAssertEqual(code(send(s, .sampleStacks(id: pid500, seconds: 2), auth: form)), .outputTooLarge)
        runner.fallback = .timedOut
        XCTAssertEqual(code(send(s, .internetSockets, auth: form)), .toolFailed)
    }

    func testSetAgentContentsNeedsHolder() {
        let s = greeted()
        XCTAssertEqual(code(send(s, .setAgentContents(true))), .notAuthorized)
        XCTAssertFalse(settings.agentContents)
        XCTAssertEqual(send(s, .setAgentContents(true), auth: form), .ok)
        XCTAssertTrue(settings.agentContents)
    }

    func testRemoveRightAndSettings() {
        let s = greeted()
        settings.agentContents = true
        XCTAssertEqual(send(s, .removeRightAndSettings), .ok)
        XCTAssertEqual(authority.removed, [HelperIDs.rightName])
        XCTAssertTrue(settings.removed)
        XCTAssertFalse(settings.agentContents)
    }

    // MARK: Data handlers

    func testListeningPrefersNetstat() {
        let s = greeted()
        runner.results[.netstatTCP] = .output("tcp4 0 0 *.22 *.* LISTEN\n")
        runner.results[.netstatUDP] = .output("udp4 0 0 *.5353 *.*\n")
        guard case .toolText(let t) = send(s, .listeningSockets, auth: form) else { return XCTFail() }
        XCTAssertTrue(t.hasPrefix("#netstat\n"))
        XCTAssertTrue(t.contains("*.22") && t.contains("\n#udp\nudp4 0 0 *.5353"))
        XCTAssertFalse(runner.calls.contains(.lsofListening))
    }

    func testListeningFallsBackToLsof() {
        let s = greeted()
        runner.results[.netstatTCP] = .output("")
        runner.results[.netstatUDP] = .output("")
        runner.results[.lsofListening] = .output("COMMAND PID USER\n")
        guard case .toolText(let t) = send(s, .listeningSockets, auth: form) else { return XCTFail() }
        XCTAssertTrue(t.hasPrefix("#lsof\n"))
    }

    func testBackgroundItemsParsed() {
        let s = greeted()
        runner.results[.sfltoolDumpbtm] = .output(HelperFixtures.dumpbtm)
        guard case .backgroundItems(let items) = send(s, .backgroundItems, auth: form) else { return XCTFail() }
        XCTAssertEqual(items.count, 2)
    }

    func testUnparseableProfilesRefused() {
        let s = greeted()
        runner.results[.profilesDevice] = .output("garbage")
        XCTAssertEqual(code(send(s, .deviceProfiles, auth: form)), .toolFailed)
    }

    func testSnapshotSizesParsed() {
        let s = greeted()
        runner.results[.tmutilSnapshots] = .output(HelperFixtures.tmutilSized)
        guard case .snapshotSizes(let sizes) = send(s, .snapshotSizes, auth: form) else { return XCTFail() }
        XCTAssertEqual(sizes.count, 2)
    }

    func testSampleUsesFixedArgs() {
        let s = greeted()
        runner.fallback = .output("Call graph:\n")
        guard case .toolText = send(s, .sampleStacks(id: pid500, seconds: 2), auth: form) else { return XCTFail() }
        XCTAssertEqual(runner.calls.last, .sample(pid: 500, seconds: 2))
    }

    func testInvalidParameterBeforeAuthorization() {
        let s = greeted()
        XCTAssertEqual(code(send(s, .sampleStacks(id: pid500, seconds: 60), auth: form)), .invalidParameter)
    }
}
