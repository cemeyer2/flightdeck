// Camera & Mic history file (retention, round trip, crash recovery, clear), the opt-in alert findings, and a live
// smoke test of the device listeners that only reads device state (it never opens a camera or microphone) and is
// skipped on machines without either, such as CI's virtual Macs.
import XCTest
import CoreAudio
@testable import FlightDeckCore

final class CameraMicStoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cameramic-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func session(_ app: String, daysAgo: Double, minutes: Double = 10, open: Bool = false) -> SensorSession {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return SensorSession(kind: .camera, devices: ["FaceTime HD Camera"], app: SensorApp(name: app, bundleID: "com.example.\(app)"),
                             confidence: .confirmed, how: "test", start: start, end: open ? nil : start.addingTimeInterval(minutes * 60))
    }

    func testRetentionDropsSessionsOlderThan90Days() {
        let s = CameraMicStore(preview: [session("Old", daysAgo: 120), session("Edge", daysAgo: 89), session("New", daysAgo: 1)])
        s.prune(now: now)
        XCTAssertEqual(s.sessions().compactMap(\.app?.name), ["Edge", "New"])
    }

    func testRoundTripAndKnownApps() {
        let a = CameraMicStore(dir: dir, now: now)
        a.upsert([session("Zoom", daysAgo: 2)], known: ["camera|com.example.Zoom"], now: now)
        a.flush()
        let b = CameraMicStore(dir: dir, now: now)
        XCTAssertEqual(b.sessions().count, 1)
        XCTAssertEqual(b.knownKeys, ["camera|com.example.Zoom"])
        XCTAssertEqual(b.firstSeen["camera|com.example.Zoom"], now)
    }

    func testUpsertReplacesBySessionID() {
        let s = CameraMicStore(preview: [])
        var x = session("Zoom", daysAgo: 0, open: true)
        s.upsert([x], known: [])
        x.end = x.start.addingTimeInterval(30)
        s.upsert([x], known: [])
        XCTAssertEqual(s.sessions().count, 1); XCTAssertFalse(s.sessions()[0].isOpen)
    }

    func testOpenSessionLeftByACrashIsClosedAtLastSeen() {
        let a = CameraMicStore(dir: dir, now: now)
        var x = session("Zoom", daysAgo: 0, open: true)
        x.lastSeen = x.start.addingTimeInterval(45)
        a.upsert([x], known: []); a.flush()
        let b = CameraMicStore(dir: dir, now: now)
        XCTAssertEqual(b.sessions().first?.end, x.start.addingTimeInterval(45))
        XCTAssertEqual(b.sessions().first?.endObserved, false)
    }

    func testClearRemovesSessionsAndKnownApps() {
        let a = CameraMicStore(dir: dir, now: now)
        a.upsert([session("Zoom", daysAgo: 1)], known: ["camera|com.example.Zoom"], now: now)
        a.clear(); a.flush()
        let b = CameraMicStore(dir: dir, now: now)
        XCTAssertTrue(b.sessions().isEmpty); XCTAssertTrue(b.knownKeys.isEmpty)
    }

    func testReadOnlyStoreNeverWrites() {
        let a = CameraMicStore(dir: dir, now: now, readOnly: true)
        a.upsert([session("Zoom", daysAgo: 1)], known: []); a.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(CameraMicStore.fileName).path))
    }
}

final class CameraMicFindingsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstUseAndUnattendedFindingsAreOptIn() {
        var first = SensorSession(kind: .microphone, devices: ["MacBook Pro Microphone"], app: SensorApp(name: "Zoom"), confidence: .confirmed,
                                  how: "Named by macOS's microphone indicator", start: now.addingTimeInterval(-30))
        first.firstUse = true
        let locked = SensorSession(kind: .camera, devices: ["FaceTime HD Camera"], app: nil, confidence: .unknown, how: "Unknown app: x",
                                   start: now.addingTimeInterval(-60), end: now.addingTimeInterval(-50), whileLocked: true)
        XCTAssertTrue(CameraMicFindings.findings([first, locked], settings: .init(), now: now).isEmpty)
        let f = CameraMicFindings.findings([first, locked], settings: .init(firstUse: true, lockedOrIdle: true), now: now)
        XCTAssertEqual(f.count, 2)
        XCTAssertEqual(f[0].title, "Zoom used the microphone for the first time")
        XCTAssertTrue(f.allSatisfy { $0.id.hasPrefix("privacy:") && $0.destination == "Camera & Mic" })
        XCTAssertEqual(f[1].title, "The camera came on while the screen was locked: Unknown app")
        XCTAssertEqual(f[1].severity, .warning)
        // Gone once the session has been over for longer than the linger.
        let later = now.addingTimeInterval(CameraMicFindings.linger + 60)
        XCTAssertEqual(CameraMicFindings.findings([locked], settings: .init(lockedOrIdle: true), now: later).count, 0)
    }
}

final class CameraMicLiveTests: XCTestCase {
    /// Registers the real listeners and reads the devices once. Only reads state; never opens a device.
    func testWatchStartsAndReadsDevices() throws {
        let audio = AudioInputMonitor(queue: DispatchQueue(label: "test.audio"))
        let video = VideoDeviceMonitor(queue: DispatchQueue(label: "test.video"))
        let hasInput = !AudioInputMonitor.ids(AudioInputMonitor.system, kAudioHardwarePropertyDevices)
            .filter { AudioInputMonitor.streamCount($0, kAudioObjectPropertyScopeInput) > 0 }.isEmpty
        let cams = video.read().all
        try XCTSkipIf(!hasInput && cams.isEmpty, "no camera or audio input on this machine (CI)")
        _ = audio.read()
        let w = CameraMicWatch(store: CameraMicStore(preview: []))
        let changed = expectation(description: "first reading")
        changed.assertForOverFulfill = false
        w.onChange = { changed.fulfill() }
        w.start()
        wait(for: [changed], timeout: 5)
        XCTAssertNotNil(w.live.since)
        XCTAssertEqual(w.live.cameras.count, cams.count)
        w.stop()
    }
}
