// Camera & Mic: the privacy indicator's log lines, the session tracker (open/close, overlap, attribution, first use),
// the history file (retention, crash recovery, clear) and the alert findings. The "aud", "scr" and "loc" lines are
// captured verbatim from macOS 27.2's unified log; the "mic"/"cam" lines use the same format with invented apps.
import XCTest
@testable import FlightDeckCore

final class CameraMicParserTests: XCTestCase {
    func testQuotedActiveSet() {
        let a = IndicatorLogParser.parse(message: #"Active activity attributions changed to ["aud:com.rogueamoeba.arkaudiod", "scr:com.googlecode.iterm2"]"#)
        XCTAssertEqual(a?.map(\.code), ["aud", "scr"])
        XCTAssertEqual(a?.map(\.bundleID), ["com.rogueamoeba.arkaudiod", "com.googlecode.iterm2"])
        XCTAssertEqual(a?.compactMap(\.kind), [], "system-audio and screen recording aren't camera or microphone")
        let m = IndicatorLogParser.parse(message: #"Active activity attributions changed to ["mic:us.zoom.xos", "cam:us.zoom.xos"]"#)
        XCTAssertEqual(m?.compactMap(\.kind), [.microphone, .camera])
        XCTAssertEqual(IndicatorLogParser.parse(message: "Active activity attributions changed to []"), [])
    }

    func testBracketedWithNamesContainingParentheses() {
        let a = IndicatorLogParser.parse(message: "Sorted active attributions from SystemStatus update: [[aud] Audio Routing Kit (ARK) (com.rogueamoeba.arkaudiod), [loc] Weather (com.apple.weather)]")
        XCTAssertEqual(a, [IndicatorAttribution(code: "aud", bundleID: "com.rogueamoeba.arkaudiod", name: "Audio Routing Kit (ARK)"),
                           IndicatorAttribution(code: "loc", bundleID: "com.apple.weather", name: "Weather")])
        let b = IndicatorLogParser.parse(message: "Sorted active attributions from SystemStatus update: [[cam] Photo Booth, Pro (com.apple.PhotoBooth), [mic] zoom.us (us.zoom.xos)]")
        XCTAssertEqual(b?.map(\.name), ["Photo Booth, Pro", "zoom.us"])
        XCTAssertEqual(b?.compactMap(\.kind), [.camera, .microphone])
        XCTAssertEqual(IndicatorLogParser.parse(message: "Sorted active attributions from SystemStatus update: []"), [])
    }

    func testOtherLinesAreNotStatesOfTheActiveSet() {
        XCTAssertNil(IndicatorLogParser.parse(message: #"Recent activity attributions changed to ["aud:com.rogueamoeba.arkaudiod"]"#))
        XCTAssertNil(IndicatorLogParser.parse(message: "SystemStatus attributed attribution to com.rogueamoeba.arkaudiod, displayName: <private>, bundlePath: <private>, executablePath: <private>, isSystemExecutable: false"))
        XCTAssertNil(IndicatorLogParser.parse(message: "Pausing sensor indicator popover requests"))
        // Malformed or truncated: nil, never a guess.
        XCTAssertNil(IndicatorLogParser.parse(message: #"Active activity attributions changed to ["mic:us.zoom"#))
        XCTAssertNil(IndicatorLogParser.parse(message: "Sorted active attributions from SystemStatus update: [[mic] zoom.us]"))
    }

    func testNDJSONLine() {
        let line = #"{"messageType":"Default","eventType":"logEvent","formatString":"Sorted active attributions from SystemStatus update: %{public}s","subsystem":"com.apple.controlcenter","category":"sensor-indicators","processImagePath":"\/System\/Library\/CoreServices\/ControlCenter.app\/Contents\/MacOS\/ControlCenter","timestamp":"2026-11-18 19:36:57.267269-0600","eventMessage":"Sorted active attributions from SystemStatus update: [[aud] Audio Routing Kit (ARK) (com.rogueamoeba.arkaudiod)]","processID":731}"#
        let r = IndicatorLogParser.parse(ndjson: Data(line.utf8))
        XCTAssertEqual(r?.active.first?.bundleID, "com.rogueamoeba.arkaudiod")
        XCTAssertEqual(r?.time?.timeIntervalSince1970 ?? 0, 1_795_052_217.267, accuracy: 0.01)
        XCTAssertNil(IndicatorLogParser.parse(ndjson: Data(#"Filtering the log data using "subsystem == ...""#.utf8)))
    }

    func testLineSplitterAcrossChunks() {
        let s = LineSplitter()
        XCTAssertEqual(s.feed(Data("ab".utf8)), [])
        XCTAssertEqual(s.feed(Data("c\nde\nf".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["abc", "de"])
        XCTAssertEqual(s.feed(Data("\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["f"])
    }
}

final class CameraMicTrackerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let mic = SensorDevice(uid: "BuiltInMic", name: "MacBook Pro Microphone", kind: .microphone, transport: "Built-in")
    let cam = SensorDevice(uid: "FaceTimeHD", name: "FaceTime HD Camera", kind: .camera, transport: "Built-in")

    func obs(mic m: Bool = false, cam c: Bool = false, clients: [AudioInputClient] = [], indicator: [IndicatorAttribution]? = nil,
             front: SensorApp? = nil, locked: Bool = false, idle: TimeInterval = 0) -> SensorObservation {
        var o = SensorObservation()
        o.running = [.microphone: m ? [mic] : [], .camera: c ? [cam] : []]
        o.audioClients = clients; o.indicator = indicator; o.frontmost = front; o.screenLocked = locked; o.idleSeconds = idle
        return o
    }
    /// A tracker that has already seen one idle observation, so later sessions count as observed from their start.
    func tracker(known: Set<String> = []) -> CameraMicTracker {
        let t = CameraMicTracker(known: known); t.update(obs(), at: t0.addingTimeInterval(-60)); return t
    }

    func testOpenAndCloseCameraSession() {
        let t = tracker()
        let opened = t.update(obs(cam: true, indicator: [.init(code: "cam", bundleID: "com.apple.FaceTime", name: "FaceTime")]), at: t0)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened[0].app?.name, "FaceTime"); XCTAssertEqual(opened[0].confidence, .confirmed)
        XCTAssertEqual(opened[0].devices, ["FaceTime HD Camera"]); XCTAssertTrue(opened[0].startObserved)
        XCTAssertTrue(opened[0].isOpen)
        let closed = t.update(obs(indicator: []), at: t0.addingTimeInterval(120))
        XCTAssertEqual(closed.count, 1); XCTAssertEqual(closed[0].id, opened[0].id)
        XCTAssertEqual(closed[0].duration(), 120, accuracy: 0.001)
        XCTAssertTrue(t.open.isEmpty)
    }

    func testMicFromCoreAudioClientIsConfirmedWithPID() {
        let t = tracker()
        let s = t.update(obs(mic: true, clients: [AudioInputClient(pid: 812, bundleID: "com.apple.VoiceMemos", devices: ["MacBook Pro Microphone"])]), at: t0)
        XCTAssertEqual(s.first?.app?.pid, 812); XCTAssertEqual(s.first?.confidence, .confirmed)
        XCTAssertTrue(s.first?.how.contains("CoreAudio") == true)
    }

    func testAppleHelperIsFoldedIntoTheNamedApp() {
        let t = tracker()
        let s = t.update(obs(mic: true, clients: [AudioInputClient(pid: 699, bundleID: "com.apple.avconferenced", devices: ["MacBook Pro Microphone"])],
                             indicator: [.init(code: "mic", bundleID: "com.apple.FaceTime")]), at: t0)
        XCTAssertEqual(s.count, 1, "avconferenced records for FaceTime; it's not a second app")
        XCTAssertEqual(s[0].app?.bundleID, "com.apple.FaceTime")
        XCTAssertTrue(s[0].how.contains("avconferenced"))
    }

    func testOverlappingSessions() {
        let t = tracker()
        // Zoom: camera and microphone; then Voice Memos joins the microphone; Zoom leaves; Voice Memos stays.
        let zoom = [IndicatorAttribution(code: "mic", bundleID: "us.zoom.xos", name: "zoom.us"), .init(code: "cam", bundleID: "us.zoom.xos", name: "zoom.us")]
        XCTAssertEqual(t.update(obs(mic: true, cam: true, indicator: zoom), at: t0).count, 2)
        let both = zoom + [.init(code: "mic", bundleID: "com.apple.VoiceMemos", name: "Voice Memos")]
        t.update(obs(mic: true, cam: true, indicator: both), at: t0.addingTimeInterval(60))
        XCTAssertEqual(t.open.count, 3)
        let after = t.update(obs(mic: true, indicator: [.init(code: "mic", bundleID: "com.apple.VoiceMemos", name: "Voice Memos")]), at: t0.addingTimeInterval(300))
        let ended = after.filter { !$0.isOpen }
        XCTAssertEqual(Set(ended.map(\.kind)), [.camera, .microphone]); XCTAssertTrue(ended.allSatisfy { $0.app?.bundleID == "us.zoom.xos" })
        XCTAssertEqual(t.open.count, 1); XCTAssertEqual(t.open.values.first?.app?.name, "Voice Memos")
        XCTAssertEqual(t.open.values.first?.start, t0.addingTimeInterval(60))
    }

    func testUnknownRenamedWhenTheNameArrivesWithinGrace() {
        let t = tracker()
        let first = t.update(obs(cam: true), at: t0)
        XCTAssertEqual(first.first?.confidence, .unknown); XCTAssertEqual(first.first?.appLabel, "Unknown app")
        XCTAssertTrue(first.first?.how.contains("couldn't be read") == true)
        let named = t.update(obs(cam: true, indicator: [.init(code: "cam", bundleID: "com.apple.PhotoBooth", name: "Photo Booth")]), at: t0.addingTimeInterval(2))
        XCTAssertEqual(named.count, 1); XCTAssertEqual(named[0].id, first[0].id); XCTAssertEqual(named[0].start, t0)
        XCTAssertEqual(named[0].app?.name, "Photo Booth"); XCTAssertEqual(t.open.count, 1)
    }

    func testUnknownStaysUnknownAfterGrace() {
        let t = tracker()
        t.update(obs(cam: true, indicator: []), at: t0)
        let later = t.update(obs(cam: true, indicator: [.init(code: "cam", bundleID: "com.apple.PhotoBooth")]), at: t0.addingTimeInterval(60))
        XCTAssertEqual(later.count, 2, "the unknown session ends and a named one starts")
        XCTAssertEqual(later.first { !$0.isOpen }?.confidence, .unknown)
        XCTAssertTrue(later.first { !$0.isOpen }?.how.contains("didn't name") == true)
    }

    func testLikelyGuessIsLabelledAndNeverFirstUse() {
        let t = tracker()
        let s = t.update(obs(cam: true, indicator: [], front: SensorApp(name: "Photo Booth", bundleID: "com.apple.PhotoBooth")), at: t0)
        XCTAssertEqual(s.first?.confidence, .likely); XCTAssertEqual(s.first?.appLabel, "likely Photo Booth")
        XCTAssertFalse(s.first?.firstUse ?? true)
        XCTAssertTrue(t.known.isEmpty)
    }

    func testRejoinAfterABriefBlip() {
        let t = tracker()
        let a = t.update(obs(mic: true, indicator: [.init(code: "mic", bundleID: "us.zoom.xos")]), at: t0)
        t.update(obs(indicator: []), at: t0.addingTimeInterval(10))
        let b = t.update(obs(mic: true, indicator: [.init(code: "mic", bundleID: "us.zoom.xos")]), at: t0.addingTimeInterval(12))
        XCTAssertEqual(b.first?.id, a.first?.id); XCTAssertTrue(b.first?.isOpen == true)
        t.update(obs(indicator: []), at: t0.addingTimeInterval(20))
        let c = t.update(obs(mic: true, indicator: [.init(code: "mic", bundleID: "us.zoom.xos")]), at: t0.addingTimeInterval(60))
        XCTAssertNotEqual(c.first?.id, a.first?.id, "a long gap is a new session")
    }

    func testFirstUseDetection() {
        let t = tracker(known: ["camera|com.apple.FaceTime"])
        let ft = t.update(obs(cam: true, indicator: [.init(code: "cam", bundleID: "com.apple.FaceTime")]), at: t0)
        XCTAssertFalse(ft[0].firstUse, "FaceTime used the camera before")
        t.update(obs(indicator: []), at: t0.addingTimeInterval(30))
        let zoomCam = t.update(obs(cam: true, indicator: [.init(code: "cam", bundleID: "us.zoom.xos")]), at: t0.addingTimeInterval(100))
        XCTAssertTrue(zoomCam[0].firstUse)
        let zoomMic = t.update(obs(mic: true, cam: true, indicator: [.init(code: "cam", bundleID: "us.zoom.xos"), .init(code: "mic", bundleID: "us.zoom.xos")]),
                               at: t0.addingTimeInterval(110)).first { $0.kind == .microphone }
        XCTAssertTrue(zoomMic?.firstUse == true, "first use is per kind of device")
        t.update(obs(indicator: []), at: t0.addingTimeInterval(200))
        let again = t.update(obs(cam: true, indicator: [.init(code: "cam", bundleID: "us.zoom.xos")]), at: t0.addingTimeInterval(400))
        XCTAssertFalse(again[0].firstUse)
        XCTAssertEqual(t.known, ["camera|com.apple.FaceTime", "camera|us.zoom.xos", "microphone|us.zoom.xos"])
    }

    func testInUseAtLaunchIsNeitherObservedNorFirstUse() {
        let t = CameraMicTracker()
        let s = t.update(obs(mic: true, indicator: [.init(code: "mic", bundleID: "us.zoom.xos")]), at: t0)
        XCTAssertFalse(s[0].startObserved); XCTAssertFalse(s[0].firstUse)
        XCTAssertTrue(t.known.contains("microphone|us.zoom.xos"))
        let closed = t.closeAll(at: t0.addingTimeInterval(5))
        XCTAssertFalse(closed[0].endObserved); XCTAssertTrue(t.open.isEmpty)
    }

    func testLockedAndIdleAreNotedAtStart() {
        let t = tracker()
        let s = t.update(obs(mic: true, locked: true, idle: 900), at: t0)
        XCTAssertTrue(s[0].whileLocked); XCTAssertTrue(s[0].whileIdle)
        let u = t.update(obs(mic: true, cam: true, idle: 10), at: t0.addingTimeInterval(1)).first { $0.kind == .camera }
        XCTAssertFalse(u?.whileIdle ?? true)
    }

    func testUnusualHour() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let threeAM = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 3))!
        let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12))!
        XCTAssertTrue(SensorSession(kind: .camera, devices: [], app: nil, confidence: .unknown, how: "", start: threeAM).atUnusualHour(cal))
        XCTAssertFalse(SensorSession(kind: .camera, devices: [], app: nil, confidence: .unknown, how: "", start: noon).atUnusualHour(cal))
    }
}
