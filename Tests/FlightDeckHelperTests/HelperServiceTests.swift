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
        XCTAssertEqual(BoundedToolRunner().run(path: "/nonexistent/tool", arguments: []), .failed)
    }

    func testRunnerToolArgumentsAreConstants() {
        XCTAssertEqual(HelperTool.sample(pid: 42, seconds: 3).arguments, ["42", "3"])
        XCTAssertEqual(HelperTool.footprint(pid: 42).arguments, ["42"])
        let all: [HelperTool] = [.netstatTCP, .netstatUDP, .lsofListening, .lsofInternet, .tmutilSnapshots, .profilesDevice,
                                 .sfltoolDumpbtm, .sample(pid: 1, seconds: 1), .footprint(pid: 1)]
        for t in all { XCTAssertTrue(t.path.hasPrefix("/usr/") || t.path.hasPrefix("/bin/"), t.path) }
    }
}
