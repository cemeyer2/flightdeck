// Chrome tabs: the companion extension's manifest and pinned ID, host-mode argv detection, message framing, message
// validation, host derivation, title sanitising and the label and text builders.
import XCTest
import CryptoKit
@testable import FlightDeckCore

final class ChromeTabsTests: XCTestCase {
    let extDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Extensions/Chrome")

    func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: extDir.appendingPathComponent("manifest.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Chrome's ID for an unpacked extension: SHA-256 of the DER public key, first 16 bytes as hex, 0-f mapped to a-p.
    func derivedID(_ key: String) -> String {
        let der = Data(base64Encoded: key) ?? Data()
        let hex = SHA256.hash(data: der).prefix(16).map { String(format: "%02x", $0) }.joined()
        return String(hex.map { Character(UnicodeScalar(UInt8(Int(String($0), radix: 16)! + 97))) })
    }

    // MARK: Extension

    func testExtensionManifestPermissionsExact() throws {
        let m = try manifest()
        XCTAssertEqual(Set(try XCTUnwrap(m["permissions"] as? [String])), ["tabs", "webNavigation", "nativeMessaging"])
        XCTAssertNil(m["host_permissions"]); XCTAssertNil(m["content_scripts"]); XCTAssertNil(m["optional_permissions"])
        XCTAssertEqual((m["externally_connectable"] as? [String: Any])?["ids"] as? [String], [])
        XCTAssertEqual(m["manifest_version"] as? Int, 3)
        XCTAssertEqual(m["name"] as? String, ChromeTabsConstants.extensionName)
    }

    func testExtensionIDMatchesManifestKey() throws {
        XCTAssertEqual(derivedID(try XCTUnwrap(try manifest()["key"] as? String)), ChromeTabsConstants.extensionIDs[0])
        XCTAssertEqual(ChromeTabsConstants.allowedOrigins, ChromeTabsConstants.extensionIDs.map { "chrome-extension://\($0)/" })
    }

    func testBackgroundHasNoExternalListenersOrLogging() throws {
        let js = try String(contentsOf: extDir.appendingPathComponent("background.js"), encoding: .utf8)
        for banned in ["onMessageExternal", "onConnectExternal", "console.log", "console.info", "console.debug", "console.warn", "console.error"] {
            XCTAssertFalse(js.contains(banned), banned)
        }
        XCTAssertTrue(js.contains(ChromeTabsConstants.hostName))
    }
}
