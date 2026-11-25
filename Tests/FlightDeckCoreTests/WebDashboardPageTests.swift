// Web dashboard, part 6: the page is a constant whose one inline script is pinned by hash in the CSP, writes text
// only through textContent/setAttribute, and loads nothing from anywhere else.
import XCTest
import CryptoKit
@testable import FlightDeckCore

final class WebDashboardPageTests: XCTestCase {
    func testHashMatchesScript() throws {
        let html = WebDashboardPage.html
        XCTAssertEqual(html.components(separatedBy: "<script").count, 2, "exactly one script element")
        let open = try XCTUnwrap(html.range(of: "<script>")), close = try XCTUnwrap(html.range(of: "</script>"))
        let body = String(html[open.upperBound..<close.lowerBound])
        XCTAssertEqual(body, WebDashboardPage.script)
        XCTAssertEqual(Data(SHA256.hash(data: Data(body.utf8))).base64EncodedString(), WebDashboardPage.scriptHash)
        XCTAssertTrue(WebDashboardPage.csp.contains("script-src 'sha256-\(WebDashboardPage.scriptHash)'"))
        XCTAssertEqual(WebDashboardPage.csp, "default-src 'none'; script-src 'sha256-\(WebDashboardPage.scriptHash)'; style-src 'unsafe-inline'; "
                       + "img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
    }

    func testNoDangerousSinks() throws {
        let html = WebDashboardPage.html
        for sink in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "DOMParser", "eval(", "Function(", "javascript:"] {
            XCTAssertFalse(html.contains(sink), sink)
        }
        let re = try NSRegularExpression(pattern: #"\son[a-z]+\s*="#)
        let hits = re.matches(in: html, range: NSRange(html.startIndex..., in: html)).map { String(html[Range($0.range, in: html)!]) }
        XCTAssertEqual(hits, [], "no inline event handlers")
    }

    func testNoExternalLoads() {
        let html = WebDashboardPage.html
        for bad in ["http://", "https://", "//cdn", "src="] { XCTAssertFalse(html.contains(bad), bad) }
        XCTAssertFalse(WebDashboardPage.favicon.contains("href"), "the icon references nothing")
        XCTAssertTrue(WebDashboardPage.favicon.hasPrefix("<svg"))
    }

    func testUsesStreamAndState() {
        let html = WebDashboardPage.html
        for want in ["/api/stream", "textContent", "prefers-color-scheme", "EventSource.CLOSED", "Reconnecting…", "Demo data",
                     "Sampling paused on the Mac", "while FlightDeck is in the background", "<h1", "<h2", "<th"] {
            XCTAssertTrue(html.contains(want), want)
        }
    }
}
