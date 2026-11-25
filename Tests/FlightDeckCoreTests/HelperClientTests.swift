import XCTest
@testable import FlightDeckCore
import FlightDeckHelperProtocol

final class HelperClientTests: XCTestCase {
    let eligible = HelperBuildStatus.eligible(teamID: "ABCDE12345")
    let usage = HelperRusage(cpuNs: 1, diskRead: 2, diskWritten: 3, energyNJ: 4, idleWakeups: 5, physFootprint: 6, threads: 7)

    func inputs(_ f: (inout HelperStatusInputs) -> Void) -> HelperStatusInputs {
        var i = HelperStatusInputs(userEnabled: true, build: eligible, registration: .enabled, hello: .ok(rightInPlace: true))
        f(&i)
        return i
    }

    // MARK: Status

    func testAdHocAlwaysNeedsSignedBuild() {
        let s = HelperStatus.resolve(inputs { $0.build = .needsSignedBuild })
        XCTAssertEqual(s, .needsSignedBuild)
        XCTAssertFalse(s.toggleEnabled)
        XCTAssertEqual(s.title, "Needs a signed build")
        XCTAssertEqual(s.explanation, "The helper runs as root, so FlightDeck only installs it from a build signed with a Developer ID. Everything else works as usual.")
        XCTAssertNil(s.fix)
    }

    func testDemoIsOff() {
        XCTAssertEqual(HelperStatus.resolve(inputs { $0.demo = true }), .off)
        XCTAssertEqual(HelperStatus.resolve(inputs { $0.userEnabled = false }), .off)
        XCTAssertEqual(HelperStatus.off.title, "Off")
    }

    func testTranslocated() {
        let s = HelperStatus.resolve(inputs { $0.build = .moveToApplications })
        XCTAssertEqual(s, .moveToApplications)
        XCTAssertEqual(s.title, "Move FlightDeck to Applications first")
    }

    func testWaitingForApproval() {
        let s = HelperStatus.resolve(inputs { $0.registration = .requiresApproval })
        XCTAssertEqual(s, .waitingForApproval)
        XCTAssertEqual(s.fix, .openLoginItems)
        XCTAssertEqual(s.title, "Waiting for approval in Login Items")
    }

    func testMismatchOnceIsNotResponding() {
        XCTAssertEqual(HelperStatus.resolve(inputs { $0.hello = .mismatch }), .notResponding)
    }

    func testMismatchTwiceIsOutOfDate() {
        let s = HelperStatus.resolve(inputs { $0.hello = .mismatch; $0.mismatchSurvivedRelaunch = true })
        XCTAssertEqual(s, .outOfDate)
        XCTAssertEqual(s.fix, .reinstall)
    }

    func testRightMissingFails() {
        let s = HelperStatus.resolve(inputs { $0.hello = .ok(rightInPlace: false) })
        XCTAssertEqual(s, .failed("couldn't set up the administrator check"))
        XCTAssertEqual(s.title, "Failed (couldn't set up the administrator check)")
        XCTAssertEqual(HelperStatus.resolve(inputs { $0.hello = .refused(.bundleMissing) }), .failed("the helper couldn't find FlightDeck"))
    }

    /// The helper's own signature check refusing this copy is a failure with no fix, never Locked with an Unlock
    /// button that can't do anything.
    func testHelperRefusalIsNotLocked() {
        let s = HelperStatus.resolve(inputs { $0.hello = .refused(.notEligible) })
        XCTAssertEqual(s, .failed("the helper didn't accept this copy's signature"))
        XCTAssertNil(s.fix)
        XCTAssertEqual(HelperStatus.resolve(inputs { $0.hello = .refused(.notAuthorized) }),
                       .failed("the helper refused to connect (notAuthorized)"))
    }

    func testRegistrationProblems() {
        XCTAssertEqual(HelperStatus.resolve(inputs { $0.registrationRefused = true }), .notSupported)
        XCTAssertEqual(HelperStatus.notSupported.title, "Not supported on this macOS")
        XCTAssertEqual(HelperStatus.resolve(inputs { $0.registrationError = "x" }), .failed("x"))
        XCTAssertEqual(HelperStatus.resolve(inputs { $0.notResponding = true }), .notResponding)
    }

    func testToggleOnButNotRegisteredIsNotLocked() {
        XCTAssertEqual(HelperStatus.resolve(inputs { $0.registration = .notRegistered; $0.hello = nil }), .off)
        XCTAssertEqual(HelperStatus.resolve(inputs { $0.registration = .notFound; $0.hello = nil }), .off)
        // A failed register() is still shown as such.
        XCTAssertEqual(HelperStatus.resolve(inputs { $0.registration = .notRegistered; $0.registrationError = "x" }), .failed("x"))
    }

    func testLockedAndUnlocked() {
        let locked = HelperStatus.resolve(inputs { _ in })
        XCTAssertEqual(locked, .locked)
        XCTAssertEqual(locked.fix, .unlock)
        XCTAssertEqual(locked.title, "On · Locked")
        let unlocked = HelperStatus.resolve(inputs { $0.unlocked = true })
        XCTAssertEqual(unlocked, .unlocked)
        XCTAssertEqual(unlocked.fix, .lock)
        XCTAssertEqual(unlocked.title, "On · Unlocked")
    }

    // MARK: Session

    func ids(_ n: Int) -> [ProcessIdentity] { (1...n).map { ProcessIdentity(pid: Int32($0), startTime: 1) } }

    func testDeadlineExceededReturnsNil() {
        let fake = FakeHelperClient()
        let s = HelperSession.unlockedForTests(fake)
        fake.echoRusage(usage)
        fake.delay = 0.5
        let start = Date()
        XCTAssertNil(s.rusage(for: ids(3)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    }

    func testBackoffAfterThreeFailures() {
        var now = Date(timeIntervalSince1970: 1000)
        let fake = FakeHelperClient()
        let s = HelperSession.unlockedForTests(fake, clock: { now })
        fake.echoRusage(usage)
        fake.delay = 0.2
        for _ in 0..<3 { XCTAssertNil(s.rusage(for: ids(2))) }
        XCTAssertEqual(fake.calls(of: "processRusage").count, 3)
        XCTAssertTrue(s.notResponding)
        XCTAssertNil(s.rusage(for: ids(2)))
        XCTAssertEqual(fake.calls(of: "processRusage").count, 3)
        now = now.addingTimeInterval(31)
        fake.delay = 0
        XCTAssertNotNil(s.rusage(for: ids(2)))
        XCTAssertEqual(fake.calls(of: "processRusage").count, 4)
        XCTAssertFalse(s.notResponding)
    }

    func testBusyIsNotAFailure() {
        let fake = FakeHelperClient()
        let s = HelperSession.unlockedForTests(fake)
        fake.replies["processRusage"] = .refused(HelperRefusal(code: .busy, message: "busy"))
        for _ in 0..<2 { XCTAssertNil(s.rusage(for: ids(1))) }
        fake.replies["processRusage"] = .refused(HelperRefusal(code: .rateLimited, message: "slow down"))
        XCTAssertNil(s.rusage(for: ids(1)))
        XCTAssertFalse(s.notResponding)
        XCTAssertEqual(fake.calls(of: "processRusage").count, 3)
    }

    func testRusageBatchCapped() {
        let fake = FakeHelperClient()
        let s = HelperSession.unlockedForTests(fake)
        fake.echoRusage(usage)
        let all = ids(5000)
        let got = s.rusage(for: all)
        XCTAssertEqual(got?.count, 5000)
        let batches = fake.calls(of: "processRusage")
        XCTAssertEqual(batches.count, 2)
        for case .processRusage(let b) in batches { XCTAssertLessThanOrEqual(b.count, HelperLimits.maxBatch) }
    }

    func testNoAuthorizationMeansLocked() {
        let fake = FakeHelperClient()
        fake.replies["hello"] = .hello(HelperHello(version: 1, rightInPlace: true, eligible: true))
        fake.replies["status"] = .status(HelperServiceStatus(unlocked: true, holderAlive: true, agentContents: true))
        let s = HelperSession(client: fake, authorization: { nil })
        XCTAssertEqual(s.state, .off)
        s.connect()
        s.refreshStatus()
        XCTAssertEqual(s.state, .locked)
        XCTAssertNil(s.rusage(for: ids(1)))
        XCTAssertTrue(fake.calls(of: "processRusage").isEmpty)
        XCTAssertEqual(HelperSession.unlockedForTests(FakeHelperClient()).state, .unlocked)
    }

    func testMismatchInvalidates() {
        let fake = FakeHelperClient()
        fake.replies["hello"] = .refused(HelperRefusal(code: .versionMismatch, message: "x"))
        let s = HelperSession(client: fake, authorization: { nil })
        XCTAssertEqual(s.connect(), .mismatch)
        XCTAssertEqual(fake.invalidations, 1)
        XCTAssertEqual(s.state, .off)
    }

    func testHelloRequiredReconnectsOnce() {
        let fake = FakeHelperClient()
        let s = HelperSession.unlockedForTests(fake)
        var first = true
        fake.handler = { r in
            guard case .processRusage = r else { return nil }
            if first { first = false; return .refused(HelperRefusal(code: .helloRequired, message: "")) }
            return .rusage([])
        }
        guard case .success(.rusage) = s.request(.processRusage(ids: []), deadline: 1) else { return XCTFail() }
        XCTAssertEqual(fake.calls(of: "hello").count, 2)
    }

    func testStandaloneNilWhenDisabledOrIneligible() {
        let suite = "HelperClientTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertNil(HelperSession.standalone(build: eligible, defaults: d))
        d.set(true, forKey: HelperSession.enabledKey)
        XCTAssertNil(HelperSession.standalone(build: .needsSignedBuild, defaults: d))
        XCTAssertNil(HelperSession.standalone(build: .moveToApplications, defaults: d))
        XCTAssertNotNil(HelperSession.standalone(build: eligible, defaults: d))
        d.set(true, forKey: "demo")
        XCTAssertNil(HelperSession.standalone(build: eligible, defaults: d))
    }

    func testStandaloneSendsNoAuthorization() {
        let fake = FakeHelperClient()
        fake.replies["hello"] = .hello(HelperHello(version: 1, rightInPlace: true, eligible: true))
        fake.replies["status"] = .status(HelperServiceStatus(unlocked: false, holderAlive: true, agentContents: true))
        let s = HelperSession(client: fake, authorization: { Data(repeating: 1, count: 32) }, clock: Date.init, standalone: true)
        s.connect(); s.refreshStatus()
        XCTAssertEqual(s.state, .unlocked)
        XCTAssertFalse(s.agentContents)
        XCTAssertTrue(fake.authorizations.allSatisfy { $0 == nil })
    }

    func testRusageReconnectsAfterHelperRestart() {
        let fake = FakeHelperClient()
        let s = HelperSession.unlockedForTests(fake)
        var restarted = true
        fake.handler = { [usage] r in
            guard case .processRusage(let ids) = r else { return nil }
            if restarted { restarted = false; return .refused(HelperRefusal(code: .helloRequired, message: "")) }
            return .rusage(ids.map { HelperRusageEntry(id: $0, rusage: usage) })
        }
        XCTAssertEqual(s.rusage(for: ids(2))?.count, 2)
        XCTAssertEqual(fake.calls(of: "hello").count, 2)
    }

    /// The helper restarts and the in-tick reconnect times out: the next tick reconnects by itself, and the app's
    /// unlock is still in effect (no second administrator prompt).
    func testUnlockSurvivesReconnectThatTimedOut() {
        let fake = FakeHelperClient()
        let s = HelperSession.unlockedForTests(fake)
        var restarted = true
        fake.handler = { [usage, fake] r in
            guard case .processRusage(let ids) = r else { return nil }
            if restarted { restarted = false; fake.unreachable = true; return .refused(HelperRefusal(code: .helloRequired, message: "")) }
            return .rusage(ids.map { HelperRusageEntry(id: $0, rusage: usage) })
        }
        XCTAssertNil(s.rusage(for: ids(1)))
        XCTAssertEqual(s.lastHello, .unreachable)
        fake.unreachable = false
        XCTAssertEqual(s.rusage(for: ids(1))?.count, 1)
        XCTAssertEqual(s.state, .unlocked)
    }

    /// After lock (disconnect), the tick never reconnects on its own.
    func testNoReconnectAfterDisconnect() {
        let fake = FakeHelperClient()
        let s = HelperSession.unlockedForTests(fake)
        fake.echoRusage(usage)
        s.disconnect()
        let hellos = fake.calls(of: "hello").count
        XCTAssertNil(s.rusage(for: ids(1)))
        XCTAssertEqual(fake.calls(of: "hello").count, hellos)
    }

    func testStandaloneFollowsHolder() {
        var now = Date(timeIntervalSince1970: 1000)
        let fake = FakeHelperClient()
        fake.replies["hello"] = .hello(HelperHello(version: 1, rightInPlace: true, eligible: true))
        fake.replies["status"] = .status(HelperServiceStatus(unlocked: false, holderAlive: true, agentContents: false))
        fake.echoRusage(usage)
        let s = HelperSession(client: fake, authorization: { nil }, clock: { now }, standalone: true)
        XCTAssertEqual(s.rusage(for: ids(1))?.count, 1)
        fake.replies["status"] = .status(HelperServiceStatus(unlocked: false, holderAlive: false, agentContents: false))
        XCTAssertNotNil(s.rusage(for: ids(1)))   // status still fresh
        now = now.addingTimeInterval(6)
        XCTAssertNil(s.rusage(for: ids(1)))
        XCTAssertEqual(s.state, .locked)
    }

    func testExternalFormNeverInErrors() {
        let fake = FakeHelperClient()
        let s = HelperSession.unlockedForTests(fake)
        fake.replies["processDetails"] = .refused(HelperRefusal(code: .notAuthorized, message: "An administrator needs to unlock FlightDeck first."))
        let r = s.request(.processDetails(id: HelperProcessID(pid: 5, startTime: 1), parts: [.args]), deadline: 1)
        guard case .failure(let e) = r else { return XCTFail() }
        let text = "\(e) \(String(describing: e)) \(String(reflecting: e))".lowercased()
        XCTAssertFalse(text.contains("abab"))
        XCTAssertFalse(text.contains("171"))   // 0xAB as a decimal byte
        for err in [HelperClientError.unreachable, .timeout, .badReply] { XCTAssertFalse(err.description.lowercased().contains("abab")) }
    }

    func testIdentityConversion() {
        let p = ProcessIdentity(pid: 9, startTime: 42)
        XCTAssertEqual(ProcessIdentity(p.helperID), p)
    }
}
