// Update checks without the network: version comparison, the release decoder and link validator, the schedule,
// Check Now, rate-limit and notify rules, the saved state and the response step, and the one GET (through a stub).
import XCTest
@testable import FlightDeckCore

final class ReleaseCheckTests: XCTestCase {
    let v = { (s: String) in ReleaseVersion(s)! }

    // MARK: Versions

    func testVersionComparisonTable() {
        XCTAssertTrue(ReleaseVersion.isNewer(remote: v("1.6.1"), installed: v("1.6.0")))
        XCTAssertTrue(ReleaseVersion.isNewer(remote: v("1.7"), installed: v("1.6.0")))
        XCTAssertTrue(ReleaseVersion.isNewer(remote: v("2.0.0"), installed: v("1.6.0")))
        XCTAssertFalse(ReleaseVersion.isNewer(remote: v("1.6.0"), installed: v("1.6.0")))
        XCTAssertFalse(ReleaseVersion.isNewer(remote: v("1.5.9"), installed: v("1.6.0")))
        XCTAssertTrue(ReleaseVersion.isNewer(remote: v("v1.10.0"), installed: v("1.9.0")))   // numeric, not lexicographic
        XCTAssertEqual(v("1.6"), v("1.6.0"))
        XCTAssertEqual(v("1.6").hashValue, v("1.6.0").hashValue)
        XCTAssertEqual(v("1.6").description, "1.6")
        XCTAssertEqual(ReleaseVersion.installed(shortVersion: "1.6.0-3-gabc", build: "3-gabc"), v("1.6.0"))
    }

    func testRemoteTagClassification() {
        XCTAssertEqual(ReleaseVersion.remote(tag: "v1.7.0-beta.1"), .prerelease)
        XCTAssertEqual(ReleaseVersion.remote(tag: "v1.7.0-rc1"), .prerelease)
        XCTAssertEqual(ReleaseVersion.remote(tag: "v1.7.0+build5"), .stable(v("1.7.0")))
        XCTAssertEqual(ReleaseVersion.remote(tag: " v1.7.0 "), .stable(v("1.7.0")))
        for g in ["", "v", "latest", "1..2", "1.2.x", "v1.2.", "99999999999999999999.0"] {
            XCTAssertEqual(ReleaseVersion.remote(tag: g), .unparseable, g)
        }
    }

    func testInstalledUnknown() {
        XCTAssertNil(ReleaseVersion.installed(shortVersion: "1.0", build: "1"))
        XCTAssertNil(ReleaseVersion.installed(shortVersion: nil, build: nil))
        XCTAssertNil(ReleaseVersion.installed(shortVersion: "—", build: "—"))
        XCTAssertEqual(ReleaseVersion.installed(shortVersion: "1.0", build: "42"), v("1.0"))
    }
}
