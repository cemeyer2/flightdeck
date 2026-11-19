import Foundation
// Camera & Mic, the privacy watch: the value types shared by the tracker (CameraMicTracker.swift), the history file
// (CameraMicStore.swift), the live monitors (CameraMicAudio/Video/LogStream.swift), alerts and the MCP tool.
//
// Only *that* a device was in use is ever recorded: which device, which app, and when. FlightDeck never opens a camera
// or microphone itself and never sees a frame or a sample of audio.

/// The two sensors macOS shows a privacy dot for (green for the camera, orange for the microphone).
public enum SensorKind: String, Codable, Sendable, CaseIterable, Hashable {
    case camera, microphone
    public var title: String { self == .camera ? "Camera" : "Microphone" }
    /// Lower-case for sentences ("Zoom used the camera").
    public var noun: String { self == .camera ? "camera" : "microphone" }
    /// SF Symbol.
    public var icon: String { self == .camera ? "video.fill" : "mic.fill" }
}

/// A capture device: a camera (CoreMediaIO) or an audio input (CoreAudio).
public struct SensorDevice: Codable, Sendable, Hashable, Identifiable {
    /// The system's unique ID for the device (CoreAudio/CoreMediaIO device UID); stable across reconnects.
    public var uid: String
    public var name: String
    public var kind: SensorKind
    /// "Built-in", "USB", "Bluetooth", "Virtual", "Continuity", "AirPlay"…; nil when the system didn't say.
    public var transport: String?
    public var id: String { kind.rawValue + ":" + uid }
    public init(uid: String, name: String, kind: SensorKind, transport: String? = nil) {
        self.uid = uid; self.name = name; self.kind = kind; self.transport = transport
    }
    /// A virtual device (Zoom's or Teams' loopback input, say) isn't a physical microphone; it's shown, but labelled.
    public var isVirtual: Bool { transport == "Virtual" }
    /// "MacBook Pro Microphone", or "ZoomAudioDevice (virtual)".
    public var label: String { isVirtual ? name + " (virtual)" : name }
}

/// The app a session is attributed to. Every field except `name` may be unknown.
public struct SensorApp: Codable, Sendable, Hashable {
    public var name: String
    public var bundleID: String?
    /// The .app bundle, or the executable for command-line tools and daemons.
    public var path: String?
    /// The process that held the device, when the system named one (CoreAudio does; the camera indicator doesn't).
    public var pid: Int32?
    public init(name: String, bundleID: String? = nil, path: String? = nil, pid: Int32? = nil) {
        self.name = name; self.bundleID = bundleID; self.path = path; self.pid = pid
    }
    /// What identifies "the same app" across sessions and launches: the bundle ID, else the path, else the name.
    public var key: String { bundleID ?? path ?? name }
}

/// How sure FlightDeck is about which app used the device. Shown with every session, so a guess never reads as fact.
public enum AttributionConfidence: String, Codable, Sendable, Hashable {
    /// macOS itself named the app: its privacy indicator (Control Center) or CoreAudio's per-process input state.
    case confirmed
    /// A guess with a stated basis (e.g. the frontmost app when the device turned on). Shown as "likely X".
    case likely
    /// Nobody said. The session still records the device and the time.
    case unknown
}

/// One stretch of a camera or microphone being in use by one app.
public struct SensorSession: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: SensorKind
    /// Names of the devices in use during the session (usually one), as labels ("MacBook Pro Microphone").
    public var devices: [String]
    /// nil when the app is unknown (see `confidence` and `how`).
    public var app: SensorApp?
    public var confidence: AttributionConfidence
    /// Plain-English basis for the attribution, e.g. "named by macOS's microphone indicator" or the reason it's unknown.
    public var how: String
    public var start: Date
    /// nil while the session is open.
    public var end: Date?
    /// The last time the session was confirmed still open; used to close sessions left open by a crash.
    public var lastSeen: Date
    /// False when the device was already in use when FlightDeck started watching: `start` is then "at least since".
    public var startObserved: Bool
    /// False when the session was closed because FlightDeck stopped (quit, crash): `end` is then "at least until".
    public var endObserved: Bool
    /// The first time this app was seen using this kind of device (only for confirmed attributions).
    public var firstUse: Bool
    /// The screen was locked, or nobody had touched the keyboard or mouse for `CameraMicTracker.idleThreshold`, when
    /// the session started.
    public var whileLocked: Bool
    public var whileIdle: Bool

    public init(id: UUID = UUID(), kind: SensorKind, devices: [String], app: SensorApp?, confidence: AttributionConfidence, how: String,
                start: Date, end: Date? = nil, startObserved: Bool = true, endObserved: Bool = true, firstUse: Bool = false,
                whileLocked: Bool = false, whileIdle: Bool = false) {
        self.id = id; self.kind = kind; self.devices = devices; self.app = app; self.confidence = confidence; self.how = how
        self.start = start; self.end = end; self.lastSeen = end ?? start; self.startObserved = startObserved
        self.endObserved = endObserved; self.firstUse = firstUse; self.whileLocked = whileLocked; self.whileIdle = whileIdle
    }

    public var isOpen: Bool { end == nil }
    public func duration(now: Date = Date()) -> TimeInterval { max(0, (end ?? now).timeIntervalSince(start)) }
    /// "Zoom", "likely Photo Booth", or "Unknown app".
    public var appLabel: String {
        guard let app else { return "Unknown app" }
        return confidence == .likely ? "likely \(app.name)" : app.name
    }
    /// Started between midnight and 6 a.m. local time (in `calendar`).
    public func atUnusualHour(_ calendar: Calendar = .current) -> Bool { calendar.component(.hour, from: start) < 6 }
}

/// A CoreAudio client process that is currently recording from a real input device.
public struct AudioInputClient: Sendable, Hashable {
    public var pid: Int32
    public var bundleID: String?
    /// Labels of the input devices it's reading.
    public var devices: [String]
    public init(pid: Int32, bundleID: String?, devices: [String]) { self.pid = pid; self.bundleID = bundleID; self.devices = devices }
}

/// What the monitors see at one moment. Built by CameraMicWatch on every device or log event, fed to the tracker.
public struct SensorObservation: Sendable {
    /// Devices of each kind that are in use. For microphones these are input devices that are running and (where
    /// macOS supports per-process input state) actually being read, not just playing audio.
    public var running: [SensorKind: [SensorDevice]] = [:]
    /// Processes reading a microphone (CoreAudio process objects). Empty when there are none or it's unsupported.
    public var audioClients: [AudioInputClient] = []
    /// What macOS's privacy indicator says is active, or nil when that isn't known (no log reading yet).
    public var indicator: [IndicatorAttribution]?
    /// The frontmost app, for a "likely" guess when nothing else names the app.
    public var frontmost: SensorApp?
    public var screenLocked = false
    /// Seconds since the last keyboard or mouse input.
    public var idleSeconds: TimeInterval = 0
    public init() {}
}
