// The annunciator lights table, shared by the Summary panel and the web dashboard.
import XCTest
@testable import FlightDeckCore

final class AnnunciatorTests: XCTestCase {
    func finding(_ id: String, _ s: Finding.Severity) -> Finding {
        Finding(id: id, severity: s, icon: "cpu", title: id, detail: nil, since: Date(timeIntervalSince1970: 1_800_000_000), destination: nil)
    }
    func light(_ label: String) -> Annunciator.Light { Annunciator.lights.first { $0.label == label }! }

    func testTableUnchanged() {
        XCTAssertEqual(Annunciator.lights.map(\.label), ["CPU", "MEM", "SWAP", "THERM", "DISK", "STORAGE", "NET", "GPU", "POWER", "HANG", "CRASH", "AWAKE"])
        XCTAssertEqual(light("CPU").key, "cpu")
        XCTAssertEqual(light("CRASH").dest, "Flight Log")
    }

    func testCpuThrottledLightsTwo() {
        let f = [finding("cpu-throttled", .caution)]
        XCTAssertEqual(Annunciator.level(light("CPU"), in: f), .caution)
        XCTAssertEqual(Annunciator.level(light("THERM"), in: f), .caution)
        XCTAssertNil(Annunciator.level(light("MEM"), in: f))
    }

    func testWorstWins() {
        let f = [finding("cpu:a", .info), finding("cpu-saturated", .warning)]
        XCTAssertEqual(Annunciator.level(light("CPU"), in: f), .warning)
        XCTAssertEqual(Annunciator.hits(light("CPU"), in: f).first?.id, "cpu-saturated")
    }
}
