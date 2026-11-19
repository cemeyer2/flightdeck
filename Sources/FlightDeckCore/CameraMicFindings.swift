import Foundation
// Camera & Mic alerts (opt-in, Settings › Alerts) as ordinary Findings, so they reach the banner, the notification
// pipeline (with its mutes), the menu bar caution light and the Flight Log like every other finding. Two kinds:
//   • an app used the camera or microphone for the first time;
//   • the camera or microphone came on while the screen was locked, or after 5 minutes without keyboard or mouse input.
// A finding lasts while its session is open and for `linger` after it ends, so a 5-second use is still seen. Ids
// start with "privacy:" (Alerts sends these at once instead of waiting for the "sustained for N minutes" delay).

public struct CameraMicAlertSettings: Sendable, Equatable {
    public var firstUse: Bool
    public var lockedOrIdle: Bool
    public init(firstUse: Bool = false, lockedOrIdle: Bool = false) { self.firstUse = firstUse; self.lockedOrIdle = lockedOrIdle }

    public static let firstUseKey = "cameraMicAlertFirstUse"
    public static let lockedKey = "cameraMicAlertLocked"
    /// Both off unless the user turned them on.
    public static func load(_ d: UserDefaults = .standard) -> CameraMicAlertSettings {
        CameraMicAlertSettings(firstUse: d.bool(forKey: firstUseKey), lockedOrIdle: d.bool(forKey: lockedKey))
    }
    public var any: Bool { firstUse || lockedOrIdle }
}

public enum CameraMicFindings {
    /// How long a finding stays after its session ends.
    public static let linger: TimeInterval = 10 * 60
    /// The Destination raw value of the Camera & Mic page.
    public static let destination = "Camera & Mic"

    public static func findings(_ sessions: [SensorSession], settings: CameraMicAlertSettings, now: Date) -> [Finding] {
        guard settings.any else { return [] }
        var out: [Finding] = []
        for s in sessions where s.isOpen || now.timeIntervalSince(s.end ?? now) <= linger {
            let device = s.devices.isEmpty ? "" : " (\(s.devices.joined(separator: ", ")))"
            let state = s.isOpen ? "still in use" : "for \(Self.span(s.duration(now: now)))"
            if settings.firstUse && s.firstUse, let app = s.app {
                out.append(Finding(id: "privacy:first:\(s.id.uuidString)", severity: .caution, icon: s.kind.icon,
                                   title: "\(app.name) used the \(s.kind.noun) for the first time",
                                   detail: "Started \(clock(s.start))\(device), \(state). \(s.how).",
                                   since: s.start, destination: destination))
            }
            if settings.lockedOrIdle && (s.whileLocked || s.whileIdle) {
                let when = s.whileLocked ? "while the screen was locked" : "while the Mac was idle"
                out.append(Finding(id: "privacy:unattended:\(s.id.uuidString)", severity: s.whileLocked ? .warning : .caution,
                                   icon: s.kind.icon, title: "The \(s.kind.noun) came on \(when): \(s.appLabel)",
                                   detail: "Started \(clock(s.start))\(device), \(state). \(s.how).",
                                   since: s.start, destination: destination))
            }
        }
        return out
    }

    static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// "45 s", "12 min", "2 h 5 min": short durations for finding text.
    public static func span(_ t: TimeInterval) -> String {
        if t < 60 { return "\(Int(t.rounded())) s" }
        if t < 3600 { return "\(Int((t / 60).rounded())) min" }
        return "\(Int(t) / 3600) h \(Int(t) % 3600 / 60) min"
    }
}
