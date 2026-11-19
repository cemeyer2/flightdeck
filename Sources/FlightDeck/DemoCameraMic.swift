// Demo mode's Camera & Mic: invented sessions over the last 30 days (Zoom stand-ups, FaceTime calls, Voice Memos,
// a Photo Booth guess, a first use today and an unknown app at 3 a.m. while the screen was locked), and a Zoom call in
// progress. Nothing here comes from this Mac; demo mode registers no listeners and writes no history.
import Foundation
import FlightDeckCore

enum DemoCameraMic {
    static let cam = "FaceTime HD Camera", mic = "MacBook Pro Microphone"
    static let zoom = SensorApp(name: "zoom.us", bundleID: "us.zoom.xos", path: "/Applications/zoom.us.app")
    static let faceTime = SensorApp(name: "FaceTime", bundleID: "com.apple.FaceTime", path: "/System/Applications/FaceTime.app")
    static let memos = SensorApp(name: "Voice Memos", bundleID: "com.apple.VoiceMemos", path: "/System/Applications/VoiceMemos.app")
    static let booth = SensorApp(name: "Photo Booth", bundleID: "com.apple.PhotoBooth", path: "/System/Applications/Photo Booth.app")
    static let loom = SensorApp(name: "Loom", bundleID: "com.loom.desktop", path: "/Applications/Loom.app")

    static func session(_ kind: SensorKind, _ app: SensorApp?, _ start: Date, minutes: Double?, confidence: AttributionConfidence = .confirmed,
                        how: String? = nil, firstUse: Bool = false, locked: Bool = false) -> SensorSession {
        SensorSession(kind: kind, devices: [kind == .camera ? cam : mic], app: app, confidence: confidence,
                      how: how ?? "Named by macOS's \(kind.noun) indicator", start: start,
                      end: minutes.map { start.addingTimeInterval($0 * 60) }, firstUse: firstUse, whileLocked: locked)
    }

    /// Deterministic: the same days and times relative to `now` on every run.
    static func sessions(now: Date, calendar: Calendar = .current) -> [SensorSession] {
        let today = calendar.startOfDay(for: now)
        func at(_ daysAgo: Int, _ h: Int, _ m: Int) -> Date {
            calendar.date(byAdding: DateComponents(day: -daysAgo, hour: h, minute: m), to: today)!
        }
        var out: [SensorSession] = []
        for d in 1...30 {
            let weekday = calendar.component(.weekday, from: at(d, 12, 0))
            if (2...6).contains(weekday) {   // weekday stand-up and an afternoon call
                let len = Double(25 + (d * 7) % 20)
                out += [session(.camera, zoom, at(d, 9, 30), minutes: len), session(.microphone, zoom, at(d, 9, 30), minutes: len)]
                if d % 3 == 0 { out.append(session(.microphone, zoom, at(d, 14, 5), minutes: 50)) }
            }
            if d % 4 == 1 {   // evening FaceTime
                out += [session(.camera, faceTime, at(d, 19, 40), minutes: 22), session(.microphone, faceTime, at(d, 19, 40), minutes: 22)]
            }
            if d % 9 == 2 { out.append(session(.microphone, memos, at(d, 8, 15), minutes: 4)) }
        }
        out.append(session(.camera, booth, at(5, 21, 10), minutes: 3, confidence: .likely,
                           how: "Guess: the app in front when the camera turned on (macOS's privacy indicator didn't name an app)"))
        // The "unknown helper": the microphone at 3 a.m. while the screen was locked, and nothing named the app.
        out.append(session(.microphone, nil, at(2, 3, 4), minutes: 6, confidence: .unknown,
                           how: "Unknown app: macOS's privacy indicator didn't name an app", locked: true))
        // Today: Voice Memos this morning, Loom for the first time, and the Zoom call in progress.
        out.append(session(.microphone, memos, at(0, 8, 2), minutes: 2))
        let loomStart = now.addingTimeInterval(-50 * 60)
        out += [session(.camera, loom, loomStart, minutes: 6, firstUse: true), session(.microphone, loom, loomStart, minutes: 6, firstUse: true)]
        out += openCall(now)
        return out.filter { $0.start <= now }
    }

    static func openCall(_ now: Date) -> [SensorSession] {
        let start = now.addingTimeInterval(-12 * 60)
        return [session(.camera, zoom, start, minutes: nil), session(.microphone, zoom, start, minutes: nil)]
    }

    static func live(now: Date) -> CameraMicLive {
        var l = CameraMicLive()
        l.since = now.addingTimeInterval(-6 * 3600)
        l.running = [.camera: [SensorDevice(uid: "demo-cam", name: cam, kind: .camera, transport: "Built-in")],
                     .microphone: [SensorDevice(uid: "demo-mic", name: mic, kind: .microphone, transport: "Built-in")]]
        l.cameras = l.running[.camera] ?? []
        l.open = openCall(now)
        l.perProcessAudio = true; l.indicatorStreaming = true
        return l
    }
}
