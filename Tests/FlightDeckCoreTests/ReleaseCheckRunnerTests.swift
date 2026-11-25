// The whole check sequence with the network, the notification and saving passed in as closures: the single retry after
// a 304 with nothing cached, one run at a time, keeping a permission flag set during the request, saving before
// notifying, and marking a version notified only after the post succeeds.
import XCTest
@testable import FlightDeckCore

@MainActor
final class ReleaseCheckRunnerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let installed = ReleaseVersion("1.6.0")!
    let ok = ReleaseHTTPResponse.http(status: 200, headers: ["ETag": "W/\"abc\""], body: ReleaseCheckTests.fixture())
    let notModified = ReleaseHTTPResponse.http(status: 304, headers: [:], body: Data())

    var fetched: [String?] = []
    var posted: [ReleaseNotice] = []
    var saved: [ReleaseCheckState] = []
    var respond: (String?) -> ReleaseHTTPResponse = { _ in .transport(.timedOut) }
    var duringFetch: () async -> Void = {}
    var delivered = true
    var duringPost: () -> Void = {}
    var runner: ReleaseCheckRunner!

    func make(_ state: ReleaseCheckState = ReleaseCheckState()) {
        runner = ReleaseCheckRunner(
            state: state, now: { [unowned self] in now },
            fetch: { [unowned self] etag in
                fetched.append(etag)
                await duringFetch()
                return respond(etag)
            },
            post: { [unowned self] notice in
                posted.append(notice)
                duringPost()
                return delivered
            },
            save: { [unowned self] in saved.append($0) })
    }

    func testRetriesOnceWithoutETagAfter304WithNothingCached() async {
        var stale = ReleaseCheckState(); stale.etag = "W/\"old\""
        make(stale)
        respond = { [unowned self] _ in notModified }
        await runner.run(installed: installed, alertsEnabled: { true })
        XCTAssertEqual(fetched, ["W/\"old\"", nil], "one retry, without If-None-Match, and no more")
        XCTAssertNil(runner.state.etag)
        XCTAssertFalse(runner.inFlight)
    }

    func testRetryThatSucceedsStoresTheRelease() async {
        var stale = ReleaseCheckState(); stale.etag = "W/\"old\""
        make(stale)
        respond = { [unowned self] etag in etag == nil ? ok : notModified }
        await runner.run(installed: installed, alertsEnabled: { true })
        XCTAssertEqual(fetched, ["W/\"old\"", nil])
        XCTAssertEqual(runner.state.latest?.version, ReleaseVersion("1.7.0"))
        XCTAssertEqual(runner.state.etag, "W/\"abc\"")
    }

    func testOnlyOneRunAtATime() async {
        make()
        respond = { [unowned self] _ in ok }
        duringFetch = { [unowned self] in
            XCTAssertTrue(runner.inFlight)
            await runner.run(installed: installed, alertsEnabled: { true })
        }
        await runner.run(installed: installed, alertsEnabled: { true })
        XCTAssertEqual(fetched.count, 1, "a run started while one is in flight makes no request")
        XCTAssertEqual(posted.count, 1)
        XCTAssertFalse(runner.inFlight)
    }

    func testKeepsPermissionFlagSetDuringTheRequest() async {
        make()
        respond = { [unowned self] _ in ok }
        duringFetch = { [unowned self] in runner.update { $0.permissionRequested = true } }
        await runner.run(installed: installed, alertsEnabled: { true })
        XCTAssertTrue(runner.state.permissionRequested)
        XCTAssertTrue(saved.last?.permissionRequested ?? false)
    }

    func testSavesBeforePostingAndMarksNotifiedOnlyAfterDelivery() async {
        make()
        respond = { [unowned self] _ in ok }
        duringPost = { [unowned self] in
            XCTAssertNil(runner.state.lastNotifiedVersion, "not marked before the post returns")
            XCTAssertEqual(saved.count, 1, "the check's result is saved before notifying")
            XCTAssertEqual(saved.first?.latest?.version, ReleaseVersion("1.7.0"))
        }
        await runner.run(installed: installed, alertsEnabled: { true })
        XCTAssertEqual(posted.map(\.version), [ReleaseVersion("1.7.0")!])
        XCTAssertEqual(runner.state.lastNotifiedVersion, "1.7.0")
        XCTAssertEqual(saved.last?.lastNotifiedVersion, "1.7.0")

        // Already notified: the next check posts nothing.
        await runner.run(installed: installed, alertsEnabled: { true })
        XCTAssertEqual(posted.count, 1)
    }

    func testUndeliveredNoticeIsNotMarked() async {
        make()
        respond = { [unowned self] _ in ok }
        delivered = false
        await runner.run(installed: installed, alertsEnabled: { true })
        XCTAssertEqual(posted.count, 1)
        XCTAssertNil(runner.state.lastNotifiedVersion)
        XCTAssertNil(saved.last?.lastNotifiedVersion)
    }

    func testAlertsOffPostsNothing() async {
        make()
        respond = { [unowned self] _ in ok }
        await runner.run(installed: installed, alertsEnabled: { false })
        XCTAssertTrue(posted.isEmpty)
        XCTAssertNil(runner.state.lastNotifiedVersion)
        XCTAssertEqual(saved.count, 1)
    }
}
