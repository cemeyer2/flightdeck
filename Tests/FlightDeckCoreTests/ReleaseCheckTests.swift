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

    // MARK: Decoder and link validator

    /// A trimmed but real-shaped `/releases/latest` body.
    static func fixture(tag: String = "v1.7.0", draft: Bool = false, prerelease: Bool = false) -> Data {
        Data("""
        {
          "url": "https://api.github.com/repos/cemeyer2/flightdeck/releases/261234567",
          "html_url": "https://github.com/cemeyer2/flightdeck/releases/tag/\(tag)",
          "id": 261234567,
          "author": { "login": "cemeyer2", "id": 1234, "type": "User", "site_admin": false },
          "node_id": "RE_kwDOexample",
          "tag_name": "\(tag)",
          "target_commitish": "main",
          "name": "FlightDeck 1.7.0",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "created_at": "2026-11-20T17:58:40Z",
          "published_at": "2026-11-20T18:04:11Z",
          "assets": [
            { "name": "FlightDeck-1.7.0.zip", "size": 9876543, "download_count": 12,
              "browser_download_url": "https://github.com/cemeyer2/flightdeck/releases/download/v1.7.0/FlightDeck-1.7.0.zip" }
          ],
          "tarball_url": "https://api.github.com/repos/cemeyer2/flightdeck/tarball/v1.7.0",
          "body": "What's new…"
        }
        """.utf8)
    }

    func testDecodesRealShapedRelease() {
        guard case .stable(let r) = ReleaseInfo.decode(Self.fixture()) else { return XCTFail("not stable") }
        XCTAssertEqual(r.version, ReleaseVersion("1.7.0"))
        XCTAssertEqual(r.tag, "v1.7.0")
        XCTAssertEqual(r.name, "FlightDeck 1.7.0")
        XCTAssertEqual(r.url.absoluteString, "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0")
        XCTAssertNotNil(r.publishedAt)
    }

    func testPrereleaseOrDraftIgnored() {
        XCTAssertEqual(ReleaseInfo.decode(Self.fixture(prerelease: true)), .noStableRelease)
        XCTAssertEqual(ReleaseInfo.decode(Self.fixture(draft: true)), .noStableRelease)
        XCTAssertEqual(ReleaseInfo.decode(Self.fixture(tag: "v1.7.0-beta.1")), .noStableRelease)
    }

    func testUnreadableBodies() {
        XCTAssertEqual(ReleaseInfo.decode(Data("<html>".utf8)), .unreadable)
        XCTAssertEqual(ReleaseInfo.decode(Data("{}".utf8)), .unreadable)
        XCTAssertEqual(ReleaseInfo.decode(Self.fixture(tag: "nightly")), .unreadable)
    }

    func testLinkValidatorAcceptsGood() {
        XCTAssertTrue(ReleaseInfo.isTrustedReleaseURL(URL(string: "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0")!))
        XCTAssertEqual(ReleaseInfo.releaseURL(htmlURL: "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0", tag: "v1.7.0").absoluteString,
                       "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0")
    }

    func testLinkValidatorFallsBack() {
        let fallback = "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0"
        let bad: [String?] = [
            "http://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0",
            "https://github.com.evil.example/cemeyer2/flightdeck/releases/tag/v1.7.0",
            "https://user:pw@github.com/cemeyer2/flightdeck/releases/tag/v1.7.0",
            "https://github.com:8443/cemeyer2/flightdeck/releases/tag/v1.7.0",
            "https://github.com/someoneelse/flightdeck/releases/tag/v1.7.0",
            nil,
        ]
        for b in bad { XCTAssertEqual(ReleaseInfo.releaseURL(htmlURL: b, tag: "v1.7.0").absoluteString, fallback, b ?? "nil") }
    }

    func testLinkValidatorRejectsTraversalAndLookalikes() {
        for s in ["https://github.com/cemeyer2/flightdeck/releases/../../evil/x",
                  "https://github.com/cemeyer2/flightdeck/releases/tag/v1?next=https://evil.example",
                  "https://GitHub.com@evil.example/cemeyer2/flightdeck/releases/tag/v1.7.0",
                  "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0#x",
                  "https://github.com/cemeyer2/flightdeck/releases/%2E%2E/x"] {
            XCTAssertFalse(ReleaseInfo.isTrustedReleaseURL(URL(string: s)!), s)
        }
        XCTAssertTrue(ReleaseInfo.isTrustedReleaseURL(URL(string: "https://GitHub.com/cemeyer2/flightdeck/releases/tag/v1.7.0")!))
    }

    func testFallbackIsPercentEncoded() {
        XCTAssertEqual(ReleaseInfo.releaseURL(htmlURL: nil, tag: "v1.7.0+build5").absoluteString,
                       "https://github.com/cemeyer2/flightdeck/releases/tag/v1.7.0%2Bbuild5")
    }
}
