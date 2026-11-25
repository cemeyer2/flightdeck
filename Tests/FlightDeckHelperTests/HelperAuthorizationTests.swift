import XCTest
@testable import FlightDeckHelperProtocol
@testable import FlightDeckHelperCore

final class HelperAuthorizationTests: XCTestCase {
    func testRuleKeys() {
        let rule = HelperRight.rule
        XCTAssertEqual(rule["shared"] as? Bool, false)
        XCTAssertEqual(rule["allow-root"] as? Bool, false)
        XCTAssertEqual(rule["class"] as? String, "user")
        XCTAssertEqual(rule["group"] as? String, "admin")
        XCTAssertEqual(rule["authenticate-user"] as? Bool, true)
        XCTAssertEqual(rule["session-owner"] as? Bool, false)
        XCTAssertNil(rule["timeout"])
    }

    func testMatchesIgnoresSystemAddedKeys() {
        var stored = HelperRight.rule
        stored["created"] = 1.0
        stored["version"] = 1
        XCTAssertTrue(HelperRight.matches(stored: stored))
        XCTAssertFalse(HelperRight.matches(stored: nil))
    }

    func testMatchesFailsOnTimeoutOrSharedTrue() {
        var t = HelperRight.rule
        t["timeout"] = 0
        XCTAssertFalse(HelperRight.matches(stored: t))
        var s = HelperRight.rule
        s["shared"] = true
        XCTAssertFalse(HelperRight.matches(stored: s))
        var missing = HelperRight.rule
        missing["group"] = nil
        XCTAssertFalse(HelperRight.matches(stored: missing))
    }

    func testEnsureRewritesDifferentRule() {
        let a = FakeAuthority()
        var bad = HelperRight.rule
        bad["shared"] = true
        a.rules[HelperIDs.rightName] = bad
        XCTAssertTrue(RightRegistrar.ensure(a))
        XCTAssertEqual(a.setCount, 1)
        XCTAssertTrue(HelperRight.matches(stored: a.rules[HelperIDs.rightName]))
    }

    func testEnsureLeavesMatchingRule() {
        let a = FakeAuthority()
        a.rules[HelperIDs.rightName] = HelperRight.rule
        XCTAssertTrue(RightRegistrar.ensure(a))
        XCTAssertEqual(a.setCount, 0)
    }

    func testEnsureReportsFailure() {
        let a = FakeAuthority()
        a.failSet = true
        XCTAssertFalse(RightRegistrar.ensure(a))
    }

    func testUnverifiedWithoutHolderGetsNone() {
        XCTAssertEqual(UnlockRegistry().access(connection: 1, uid: 501, verified: false), .none)
    }

    func testHolderGetsFull() {
        XCTAssertEqual(UnlockRegistry().access(connection: 1, uid: 501, verified: true), .full)
    }

    func testNonHolderSameUidGetsCounters() {
        let r = UnlockRegistry()
        _ = r.access(connection: 1, uid: 501, verified: true)
        XCTAssertEqual(r.access(connection: 2, uid: 501, verified: false), .counters)
        XCTAssertEqual(r.access(connection: 2, uid: 502, verified: false), .none)
        XCTAssertTrue(r.holderAlive(uid: 501))
        XCTAssertFalse(r.holderAlive(uid: 502))
    }

    func testNonHolderLosesCountersWhenHolderCloses() {
        let r = UnlockRegistry()
        _ = r.access(connection: 1, uid: 501, verified: true)
        r.connectionClosed(1)
        XCTAssertEqual(r.access(connection: 2, uid: 501, verified: false), .none)

        let r2 = UnlockRegistry()
        _ = r2.access(connection: 1, uid: 501, verified: true)
        r2.lock(connection: 1)
        XCTAssertEqual(r2.access(connection: 2, uid: 501, verified: false), .none)
        XCTAssertFalse(r2.holderAlive(uid: 501))
    }

    func testNonHolderNeverGetsContents() {
        let r = UnlockRegistry()
        _ = r.access(connection: 1, uid: 501, verified: true)
        for _ in 0..<3 {
            XCTAssertNotEqual(r.access(connection: 2, uid: 501, verified: false), .full)
        }
        // The holder itself, asking again without a fresh verification, is no longer full either.
        XCTAssertNotEqual(r.access(connection: 1, uid: 501, verified: false), .full)
    }

    let form = Data(repeating: 0xAB, count: 32)

    func testAuthCacheIsForTheVerifiedFormOnly() {
        let r = UnlockRegistry()
        r.recordVerification(connection: 1, form: form)
        XCTAssertTrue(r.cachedVerification(connection: 1, form: form))
        XCTAssertFalse(r.cachedVerification(connection: 1, form: nil))
        XCTAssertFalse(r.cachedVerification(connection: 1, form: Data(repeating: 1, count: 32)))
        XCTAssertFalse(r.cachedVerification(connection: 2, form: form))
    }

    func testAuthCacheLastsUntilReverify() {
        var now = Date(timeIntervalSince1970: 1000)
        let r = UnlockRegistry(clock: { now })
        r.recordVerification(connection: 1, form: form)
        now = now.addingTimeInterval(HelperLimits.authReverifyInterval - 1)
        XCTAssertTrue(r.cachedVerification(connection: 1, form: form))
        now = now.addingTimeInterval(2)
        XCTAssertFalse(r.cachedVerification(connection: 1, form: form))
        r.recordVerification(connection: 1, form: form)
        r.lock(connection: 1)
        XCTAssertFalse(r.cachedVerification(connection: 1, form: form))
    }

    func testFailedVerificationEndsUnlock() {
        let r = UnlockRegistry()
        r.recordVerification(connection: 1, form: form)
        _ = r.access(connection: 1, uid: 501, verified: true)
        r.verificationFailed(connection: 1)
        XCTAssertFalse(r.cachedVerification(connection: 1, form: form))
        XCTAssertFalse(r.holderAlive(uid: 501))
        XCTAssertEqual(r.access(connection: 2, uid: 501, verified: false), .none)
    }
}
