import XCTest
@testable import FlightDeckHelperProtocol

final class HelperValidationTests: XCTestCase {
    func id(_ pid: Int32) -> HelperProcessID { HelperProcessID(pid: pid, startTime: 1) }

    func testNegativeAndZeroPidRejected() {
        XCTAssertEqual(HelperValidation.validate(.processDetails(id: id(-1), parts: [.args]))?.code, .invalidParameter)
        XCTAssertEqual(HelperValidation.validate(.sampleStacks(id: id(0), seconds: 2))?.code, .invalidParameter)
        XCTAssertNil(HelperValidation.validate(.processDetails(id: id(500), parts: [.args])))
    }

    func testSecondsOutOfRange() {
        XCTAssertEqual(HelperValidation.validate(.sampleStacks(id: id(500), seconds: 0))?.code, .invalidParameter)
        XCTAssertEqual(HelperValidation.validate(.sampleStacks(id: id(500), seconds: 6))?.code, .invalidParameter)
        XCTAssertNil(HelperValidation.validate(.sampleStacks(id: id(500), seconds: 5)))
    }

    func testOversizedBatch() {
        let ids = (1...4097).map { id(Int32($0)) }
        XCTAssertEqual(HelperValidation.validate(.processRusage(ids: ids))?.code, .invalidParameter)
        XCTAssertNil(HelperValidation.validate(.processRusage(ids: Array(ids.prefix(4096)))))
        XCTAssertNil(HelperValidation.validate(.processRusage(ids: [])))
    }

    func testEmptyDetailPartsRejected() {
        XCTAssertEqual(HelperValidation.validate(.processDetails(id: id(500), parts: []))?.code, .invalidParameter)
    }

    func testCriticalProcesses() {
        for name in ["WindowServer", "launchd", "kernel_task", "coreaudiod", "loginwindow"] {
            XCTAssertTrue(HelperValidation.isCritical(pid: 1, name: name))
            XCTAssertTrue(HelperValidation.isCritical(pid: 0, name: name))
            XCTAssertTrue(HelperValidation.isCritical(pid: 400, name: name))
        }
        XCTAssertTrue(HelperValidation.isCritical(pid: 1, name: "anything"))
        XCTAssertFalse(HelperValidation.isCritical(pid: 500, name: "Safari"))
    }

    func testTiers() {
        XCTAssertEqual(HelperRequest.hello(version: 1).tier, .control)
        XCTAssertEqual(HelperRequest.processRusage(ids: []).tier, .counters)
        XCTAssertEqual(HelperRequest.sampleStacks(id: id(5), seconds: 1).tier, .contents)
        XCTAssertEqual(HelperRequest.setAgentContents(true).tier, .contents)
        XCTAssertEqual(HelperRequest.listeningSockets.tier, .counters)
        XCTAssertEqual(HelperRequest.sampleStacks(id: id(5), seconds: 1).kind, "sampleStacks")
    }
}
