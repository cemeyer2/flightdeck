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

    // MARK: Host argv and framing

    func testHostArgvExactOriginOnly() {
        let o = ChromeTabsConstants.allowedOrigins[0]
        XCTAssertEqual(ChromeHostArgv.mode(["fd", o]), .host(origin: o))
        XCTAssertEqual(ChromeHostArgv.mode(["fd", String(o.dropLast())]), .rejected, "prefix")
        XCTAssertEqual(ChromeHostArgv.mode(["fd", o + "x/"]), .rejected, "trailing path")
        XCTAssertEqual(ChromeHostArgv.mode(["fd", "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"]), .rejected)
        XCTAssertEqual(ChromeHostArgv.mode(["fd"]), .notHost)
        XCTAssertEqual(ChromeHostArgv.mode(["fd", "--snapshot"]), .notHost)
        XCTAssertEqual(ChromeHostArgv.mode(["fd", "--chrome-host"]), .host(origin: nil))
        XCTAssertTrue(ChromeHostArgv.isHostInvocation(["fd", o]))
        XCTAssertFalse(ChromeHostArgv.isHostInvocation(["fd", "--chrome-host"]))
        XCTAssertFalse(ChromeHostArgv.isHostInvocation(["fd", o + "x/"]))
    }

    func testFramingRoundTripAndPartialReads() throws {
        let payloads = [Data("{}".utf8), Data(), Data(repeating: 0x41, count: 70_000)]
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        // Written one byte at a time from another thread, so every underlying read returns a short count.
        let all = payloads.map(ChromeFraming.encode).reduce(Data(), +)
        let writer = Thread {
            for b in all { var b = b; _ = write(fds[1], &b, 1) }
            close(fds[1])
        }
        writer.start()
        var got: [Data] = []
        while let f = try ChromeFraming.readFrame({ ChromeFraming.readExact(fd: fds[0], count: $0) }) { got.append(f) }
        close(fds[0])
        XCTAssertEqual(got, payloads)
    }

    func testFrameCapRefusesWithoutAllocating() {
        var calls: [Int] = []
        let header = withUnsafeBytes(of: UInt32(64 * 1024 * 1024)) { Data($0) }
        XCTAssertThrowsError(try ChromeFraming.readFrame { n in calls.append(n); return n == 4 ? header : Data(count: n) }) {
            XCTAssertEqual($0 as? ChromeFraming.FrameError, .tooLarge(67_108_864))
        }
        XCTAssertEqual(calls, [4], "the body is never asked for")
    }

    func testFrameAtCapAccepted() throws {
        func reader(_ len: Int) -> (Int) -> Data? {
            var first = true
            return { n in
                if first { first = false; return withUnsafeBytes(of: UInt32(len)) { Data($0) } }
                return Data(count: n)
            }
        }
        XCTAssertEqual(try ChromeFraming.readFrame(reader(ChromeTabsConstants.maxFrameBytes))?.count, ChromeTabsConstants.maxFrameBytes)
        XCTAssertThrowsError(try ChromeFraming.readFrame(reader(ChromeTabsConstants.maxFrameBytes + 1)))
    }
}
