import XCTest
@testable import FlightDeckHelperProtocol

final class HelperProtocolTests: XCTestCase {
    let id = HelperProcessID(pid: 500, startTime: 1_700_000_000_000_000)

    func testEnvelopeRoundTrip() {
        let requests: [HelperRequest] = [
            .hello(version: 1), .status, .lock, .removeRightAndSettings, .setAgentContents(true),
            .processRusage(ids: [id]), .processDetails(id: id, parts: [.args, .env]),
            .listeningSockets, .internetSockets, .snapshotSizes, .deviceProfiles, .backgroundItems,
            .sampleStacks(id: id, seconds: 3), .memoryFootprint(id: id),
        ]
        for r in requests {
            let e = HelperEnvelope(request: r, authorization: Data(repeating: 7, count: 32))
            let back = HelperWire.decode(HelperEnvelope.self, HelperWire.encode(e))
            XCTAssertEqual(back?.request, r)
            XCTAssertEqual(back?.authorization, e.authorization)
        }
    }

    func testResponseRoundTrip() {
        let refused = HelperResponse.refused(HelperRefusal(code: .processChanged, message: "x"))
        XCTAssertEqual(HelperWire.decode(HelperResponse.self, HelperWire.encode(refused)), refused)
        let r = HelperRusage(cpuNs: 1, diskRead: 2, diskWritten: 3, energyNJ: 4, idleWakeups: 5, physFootprint: 6, threads: 7)
        let rusage = HelperResponse.rusage([HelperRusageEntry(id: id, rusage: r)])
        XCTAssertEqual(HelperWire.decode(HelperResponse.self, HelperWire.encode(rusage)), rusage)
    }

    func testProtocolVersionIsOne() {
        XCTAssertEqual(HelperIDs.protocolVersion, 1)
    }

    func testDecodeGarbageIsNil() {
        XCTAssertNil(HelperWire.decode(HelperEnvelope.self, Data("{}".utf8)))
    }
}
