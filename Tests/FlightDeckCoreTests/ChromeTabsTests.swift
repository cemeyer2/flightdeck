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

    // MARK: Validation

    func frameJSON(_ id: Int = 0, process: JSON = 7, origin: String = "https://a.example") -> JSON {
        ["frameId": .int(id), "parentFrameId": -1, "processId": process, "origin": .string(origin)]
    }
    func tabJSON(_ id: JSON = 1, url: String = "https://a.example/x", title: String = "A", frames: JSON? = nil) -> JSON {
        ["tabId": id, "windowId": 1, "active": true, "audible": false, "discarded": false, "url": .string(url),
         "title": .string(title), "lastAccessed": 1_764_000_000_123.5, "frames": frames ?? [frameJSON()]]
    }
    func tabsMessage(_ tabs: [JSON]) -> Data { (["type": "tabs", "seq": 3, "tabs": .array(tabs)] as JSON).data }

    func testValidationRejectsTooManyTabs() {
        XCTAssertNotNil(ChromeTabsMessage.parse(tabsMessage(Array(repeating: tabJSON(), count: 1000))))
        XCTAssertNil(ChromeTabsMessage.parse(tabsMessage(Array(repeating: tabJSON(), count: 1001))))
    }
    func testValidationRejectsTooManyFrames() {
        XCTAssertNil(ChromeTabsMessage.parse(tabsMessage([tabJSON(frames: .array(Array(repeating: frameJSON(), count: 201)))])))
    }
    func testValidationRejectsLongStrings() {
        XCTAssertNotNil(ChromeTabsMessage.parse(tabsMessage([tabJSON(url: String(repeating: "u", count: 8192))])))
        XCTAssertNil(ChromeTabsMessage.parse(tabsMessage([tabJSON(url: String(repeating: "u", count: 8193))])))
        XCTAssertNil(ChromeTabsMessage.parse(tabsMessage([tabJSON(frames: [frameJSON(origin: String(repeating: "o", count: 2049))])])))
        XCTAssertNil(ChromeTabsMessage.parse(tabsMessage([tabJSON(title: String(repeating: "t", count: 2049))])))
        XCTAssertNil(ChromeTabsMessage.parse(tabsMessage([tabJSON(title: String(repeating: "é", count: 1025))])), "bytes, not characters")
    }
    func testValidationRejectsWrongIntegerTypes() {
        XCTAssertNil(ChromeTabsMessage.parse(tabsMessage([tabJSON(1.5)])))
        XCTAssertNil(ChromeTabsMessage.parse(tabsMessage([tabJSON(frames: [frameJSON(process: "3")])])))
        XCTAssertNil(ChromeTabsMessage.parse(tabsMessage([tabJSON(true)])))
    }
    func testValidationRejectsMissingFrames() {
        guard case .object(let o) = tabJSON() else { return XCTFail() }
        XCTAssertNil(ChromeTabsMessage.parse(tabsMessage([.object(o.filter { $0.0 != "frames" })])))
    }
    func testValidationRejectsUnknownTypeAndNonJSON() {
        XCTAssertNil(ChromeTabsMessage.parse((["type": "navigate", "url": "https://x"] as JSON).data))
        XCTAssertNil(ChromeTabsMessage.parse(Data("not json".utf8)))
        XCTAssertNil(ChromeTabsMessage.parse(Data("[1,2]".utf8)))
        XCTAssertNil(ChromeTabsMessage.parse((["type": "hello", "protocol": 1] as JSON).data), "no extensionVersion")
    }
    func testValidationAcceptsWellFormed() throws {
        let hello = ChromeTabsMessage.hello(protocol: 1, extensionVersion: "1.0.0")
        XCTAssertEqual(ChromeTabsMessage.parse(hello.encoded()), hello)
        let table = ChromeTabTable(seq: 9, tabs: [
            ChromeRawTab(tabId: 1, windowId: 2, active: true, audible: false, discarded: false, url: "https://a.example/",
                         title: "A", lastAccessed: 1_764_000_000_123.5,
                         frames: [ChromeRawFrame(frameId: 0, parentFrameId: -1, processId: 12, origin: "https://a.example")]),
            ChromeRawTab(tabId: 3, windowId: 2, active: false, audible: true, discarded: true, url: "chrome://newtab/",
                         title: "", lastAccessed: 5, frames: []),
        ])
        XCTAssertEqual(ChromeTabsMessage.parse(ChromeTabsMessage.tabs(table).encoded()), .tabs(table))
        XCTAssertEqual(ChromeTabsMessage.parse(ChromeTabsMessage.origin("chrome-extension://x/").encoded()), .origin("chrome-extension://x/"))
        XCTAssertEqual(ChromeTabsMessage.parse(ChromeTabsMessage.refresh.encoded()), .refresh)
        if case .tabs(let t)? = ChromeTabsMessage.parse(tabsMessage([tabJSON()])) { XCTAssertEqual(t.tabs[0].frames[0].processId, 7) } else { XCTFail() }
    }
}
