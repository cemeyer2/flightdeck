// The `camera_mic` MCP tool: live state with the app and its attribution, sessions newest first with flags, per-app
// totals, and "unavailable" (never an invented "not in use") when no watch is available.
import XCTest
@testable import FlightDeckCore

final class CameraMicFakeSource: MCPDataSource, @unchecked Sendable {
    let standalone = false
    let blackBoxConfig = BlackBox.Config()
    var cm: (live: CameraMicLive?, store: CameraMicStore)?
    func snapshot() async -> Snapshot? { nil }
    func findings() async -> [Finding] { [] }
    func incidents() async -> [Incident] { [] }
    func reports(since: Date) async -> [DiagnosticReport] { [] }
    func blackBox(_ tier: BlackBox.Tier, from: Date, to: Date) async -> Trace? { nil }
    func dailyHistory() async -> DailyLog.History? { nil }
    func checkup() async -> [CheckResult] { [] }
    func cameraMic() async -> (live: CameraMicLive?, store: CameraMicStore)? { cm }
}

final class MCPCameraMicTests: XCTestCase {
    let now = Date()

    func call(_ src: MCPDataSource, _ args: JSON = [:]) async throws -> JSON {
        let r = await MCPTools(source: src).call("camera_mic", arguments: args)
        XCTAssertFalse(r.isError, r.text)
        return try JSON.parse(Data(r.text.utf8))
    }

    func testLiveStateAndSessions() async throws {
        let zoom = SensorSession(kind: .camera, devices: ["FaceTime HD Camera"], app: SensorApp(name: "zoom.us", bundleID: "us.zoom.xos"),
                                 confidence: .confirmed, how: "Named by macOS's camera indicator", start: now.addingTimeInterval(-300))
        var night = SensorSession(kind: .microphone, devices: ["MacBook Pro Microphone"], app: nil, confidence: .unknown,
                                  how: "Unknown app: macOS's privacy indicator didn't name an app",
                                  start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(-86_000))
        night.whileIdle = true
        var live = CameraMicLive()
        live.since = now.addingTimeInterval(-3600)
        live.running = [.camera: [SensorDevice(uid: "c", name: "FaceTime HD Camera", kind: .camera)], .microphone: []]
        live.open = [zoom]
        let src = CameraMicFakeSource()
        src.cm = (live, CameraMicStore(preview: [zoom, night]))
        let j = try await call(src)
        XCTAssertEqual(j["camera"]?["in_use"], .bool(true))
        XCTAssertEqual(j["camera"]?["apps"]?.array?.first?["app"]?.string, "zoom.us")
        XCTAssertEqual(j["microphone"]?["in_use"], .bool(false))
        let sessions = j["sessions"]?.array ?? []
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first?["end"]?.string, "still in use", "newest first")
        XCTAssertEqual(sessions.last?["app"]?.string, "Unknown app")
        XCTAssertEqual(sessions.last?["attribution"]?.string, "unknown")
        XCTAssertEqual(sessions.last?["while_idle"], .bool(true))
        XCTAssertTrue(j["summary"]?.string?.hasPrefix("Camera in use by zoom.us; Microphone not in use") == true)
        // A one-day window drops yesterday's session.
        let one = try await call(src, ["days": .int(1), "limit": .int(1)])
        XCTAssertEqual(one["sessions"]?.array?.count, 1)
    }

    func testUnavailableWithoutAWatch() async throws {
        let j = try await call(CameraMicFakeSource())
        XCTAssertTrue(j["summary"]?.string?.hasPrefix("unavailable") == true)
        let bad = await MCPTools(source: CameraMicFakeSource()).call("camera_mic", arguments: ["days": .int(400)])
        XCTAssertTrue(bad.isError)
    }
}
