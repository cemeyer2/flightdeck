import XCTest
@testable import FlightDeckHelperProtocol

final class HelperEligibilityTests: XCTestCase {
    let devID = SigningFacts(isAdHoc: false, teamID: "ABCDE12345", hardenedRuntime: true, getTaskAllow: false, developerIDLeaf: true)

    func testDeveloperIDPasses() {
        XCTAssertEqual(HelperEligibility.evaluate(devID, bundlePath: "/Applications/FlightDeck.app"), .eligible(teamID: "ABCDE12345"))
    }

    func testAdHocNeedsSignedBuild() {
        var f = devID
        f.isAdHoc = true
        XCTAssertEqual(HelperEligibility.evaluate(f, bundlePath: "/Applications/FlightDeck.app"), .needsSignedBuild)
        XCTAssertEqual(HelperEligibility.evaluate(f, bundlePath: "build/FlightDeck.app"), .needsSignedBuild)
        XCTAssertEqual(HelperEligibility.evaluate(nil, bundlePath: "/Applications/FlightDeck.app"), .needsSignedBuild)
    }

    func testMissingTeamOrRuntimeOrTaskAllow() {
        var a = devID; a.teamID = nil
        var b = devID; b.hardenedRuntime = false
        var c = devID; c.getTaskAllow = true
        var d = devID; d.developerIDLeaf = false
        var e = devID; e.teamID = ""
        for f in [a, b, c, d, e] {
            XCTAssertEqual(HelperEligibility.evaluate(f, bundlePath: "/Applications/FlightDeck.app"), .needsSignedBuild)
        }
    }

    func testTranslocatedDeveloperID() {
        let path = "/private/var/folders/xy/T/AppTranslocation/1234-ABCD/d/FlightDeck.app"
        XCTAssertTrue(HelperEligibility.isTranslocated(path))
        XCTAssertEqual(HelperEligibility.evaluate(devID, bundlePath: path), .moveToApplications)
        var adHoc = devID; adHoc.isAdHoc = true
        XCTAssertEqual(HelperEligibility.evaluate(adHoc, bundlePath: path), .needsSignedBuild)
    }

    func testRequirementString() {
        XCTAssertEqual(HelperEligibility.callerRequirement(teamID: "ABCDE12345"),
                       "anchor apple generic and identifier \"app.flightdeck.Flightdeck\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }
}
