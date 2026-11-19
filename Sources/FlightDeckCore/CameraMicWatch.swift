import Foundation
import AppKit
import CoreGraphics
// The Camera & Mic watch: wires the CoreAudio and CoreMediaIO listeners, the indicator log stream, the session tracker
// and the history file together. Every device event leads to one re-read of the devices (coalesced over 0.2 s, since
// a call starting fires several listeners at once), an observation for the tracker and an upsert of the changed
// sessions. There is no timer: with no device in use and nothing being plugged in, this does no work at all.
//
// Threading: all monitor and tracker work happens on `queue`. `live`, `findings` and the store are safe from any
// thread; `onChange` is called on `queue` after each change.

/// The live state, as the page, the menu bar and the MCP tool show it.
public struct CameraMicLive: Sendable {
    /// Devices in use now, per kind.
    public var running: [SensorKind: [SensorDevice]] = [:]
    /// Every camera the system knows about (in use or not).
    public var cameras: [SensorDevice] = []
    public var open: [SensorSession] = []
    /// CoreAudio's per-process input state is available (macOS 14.2+), so microphone use is tied to processes.
    public var perProcessAudio = false
    /// The privacy indicator's log is being followed (only while something is in use).
    public var indicatorStreaming = false
    /// Why app names from the indicator are unavailable, if they are.
    public var indicatorProblem: String?
    /// When this run of the watch began; nil when it isn't running (demo mode, standalone MCP).
    public var since: Date?
    public init() {}
    public func inUse(_ k: SensorKind) -> Bool { !(running[k] ?? []).isEmpty || open.contains { $0.kind == k } }
}

public final class CameraMicWatch: @unchecked Sendable {
    public let store: CameraMicStore
    private let queue = DispatchQueue(label: "flightdeck.cameramic", qos: .utility)
    private let tracker: CameraMicTracker
    private let audio: AudioInputMonitor
    private let video: VideoDeviceMonitor
    private let logs: IndicatorLogStream
    // Confined to `queue`.
    private var started = false
    private var pending = false
    private var indicator: [IndicatorAttribution]?
    private var indicatorTime: Date?
    private var inUseSince: Date?
    private var stopLogs: DispatchWorkItem?
    /// How long the log stream keeps running after the last device goes idle, so a call that briefly drops the
    /// microphone (switching devices, say) doesn't restart `log` and redo the backfill.
    static let logLinger: TimeInterval = 15
    // Guarded by `lock`.
    private let lock = NSLock()
    private var liveState = CameraMicLive()
    /// Called on the watch's queue after the live state or the history changed.
    public var onChange: (@Sendable () -> Void)?

    public init(store: CameraMicStore) {
        self.store = store
        tracker = CameraMicTracker(known: store.knownKeys)
        audio = AudioInputMonitor(queue: queue)
        video = VideoDeviceMonitor(queue: queue)
        logs = IndicatorLogStream(queue: queue)
        tracker.resolve = { CameraMicWatch.resolveApp(bundle: $0, pid: $1, name: $2) }
        audio.onChange = { [weak self] in self?.schedule() }
        video.onChange = { [weak self] in self?.schedule() }
        logs.onActive = { [weak self] active, time in self?.indicatorChanged(active, time) }
    }

    /// Registers the listeners and takes the first reading. Idempotent.
    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            lock.lock(); liveState.since = Date(); lock.unlock()
            audio.start(); video.start()
            evaluate()
        }
    }

    /// Stops listening and closes open sessions as "at least until now" (FlightDeck is quitting). Synchronous.
    public func stop() {
        queue.sync {
            guard started else { return }
            started = false
            audio.stop(); video.stop(); logs.stop()
            store.upsert(tracker.closeAll(at: Date()), known: tracker.known)
            store.flush()
        }
    }

    public var live: CameraMicLive { lock.lock(); defer { lock.unlock() }; return liveState }

    /// One reading of which devices are in use, without listeners, a tracker or the log (the standalone MCP server).
    /// `since` stays nil: nothing is being watched.
    public static func reading() -> CameraMicLive {
        let q = DispatchQueue(label: "flightdeck.cameramic.reading")
        let a = AudioInputMonitor(queue: q).read(), v = VideoDeviceMonitor(queue: q).read()
        var l = CameraMicLive()
        l.running = [.microphone: a.running, .camera: v.running]; l.cameras = v.all; l.perProcessAudio = a.perProcess
        return l
    }

    /// The opt-in alert findings for now. Cheap: reads only sessions from the last few minutes.
    public func findings(settings: CameraMicAlertSettings, now: Date = Date()) -> [Finding] {
        guard settings.any else { return [] }
        return CameraMicFindings.findings(store.sessions(since: now.addingTimeInterval(-CameraMicFindings.linger)), settings: settings, now: now)
    }

    /// Clear History: deletes the file's sessions and known apps. Sessions in progress continue as new ones.
    public func clearHistory() {
        queue.async { [self] in
            store.clear(); tracker.forgetKnown()
            store.upsert(Array(tracker.open.values), known: [])
            publish()
        }
    }

    // MARK: Events (on `queue`)

    private func schedule() {
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 0.2) { [self] in pending = false; if started { evaluate() } }
    }

    private func indicatorChanged(_ active: [IndicatorAttribution], _ time: Date?) {
        // A backfill can finish after the live stream has delivered something newer; keep the newest.
        if let time, let have = indicatorTime, time < have { return }
        indicator = active; indicatorTime = time ?? Date()
        if started { evaluate() }
    }

    private func evaluate() {
        let now = Date()
        let a = audio.read(), v = video.read()
        let anyInUse = !a.running.isEmpty || !a.clients.isEmpty || !v.running.isEmpty
        manageLogStream(anyInUse, now: now)

        var o = SensorObservation()
        o.running = [.microphone: a.running, .camera: v.running]
        o.audioClients = a.clients
        o.indicator = indicator
        if anyInUse {
            // Context is only read when something is in use (it's only used for sessions starting now).
            o.frontmost = Self.frontmostApp()
            o.screenLocked = Self.screenLocked()
            o.idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        }
        let changed = tracker.update(o, at: now)
        store.upsert(changed, known: tracker.known, now: now)
        lock.lock()
        liveState.running = o.running; liveState.cameras = v.all; liveState.perProcessAudio = a.perProcess
        lock.unlock()
        publish()
    }

    /// Follows the indicator's log while anything is in use, plus `logLinger` after.
    private func manageLogStream(_ inUse: Bool, now: Date) {
        if inUse {
            stopLogs?.cancel(); stopLogs = nil
            if inUseSince == nil {
                inUseSince = now
                // From a few seconds before the device came on: the indicator may have logged just ahead of CoreAudio.
                logs.start(since: now.addingTimeInterval(-3))
            }
        } else if inUseSince != nil, stopLogs == nil {
            let w = DispatchWorkItem { [self] in
                logs.stop(); indicator = nil; indicatorTime = nil; inUseSince = nil; stopLogs = nil
                publish()
            }
            stopLogs = w
            queue.asyncAfter(deadline: .now() + Self.logLinger, execute: w)
        }
    }

    private func publish() {
        lock.lock()
        liveState.open = tracker.open.values.sorted { $0.start < $1.start }
        liveState.indicatorStreaming = logs.isRunning
        liveState.indicatorProblem = logs.failure
        lock.unlock()
        onChange?()
    }

    // MARK: System context

    /// The frontmost app, unless it's FlightDeck itself (looking at this page is no evidence of anything).
    static func frontmostApp() -> SensorApp? {
        guard let f = NSWorkspace.shared.frontmostApplication, f.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return SensorApp(name: f.localizedName ?? f.bundleIdentifier ?? "pid \(f.processIdentifier)", bundleID: f.bundleIdentifier,
                         path: f.bundleURL?.path, pid: f.processIdentifier)
    }

    static func screenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Name and path for a bundle ID and/or PID: the running process's enclosing .app (the outermost one, so a
    /// browser's helper reads as the browser), else the installed app with that bundle ID.
    static func resolveApp(bundle: String?, pid: Int32?, name: String?) -> SensorApp {
        var pid = pid, path: String?
        if let p = pid, p > 0 {
            var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(p, &buf, UInt32(buf.count)) > 0 { let exe = String(cString: buf); path = outermostApp(exe) ?? exe }
        }
        if path == nil, let bundle {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            if pid == nil { pid = running?.processIdentifier }
            path = (running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle))?.path
        }
        var display = name
        if display == nil, let path, path.hasSuffix(".app"), let info = Bundle(path: path)?.infoDictionary {
            display = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        }
        if display == nil, let path { display = ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        return SensorApp(name: display ?? bundle ?? pid.map { "pid \($0)" } ?? "Unknown app", bundleID: bundle, path: path, pid: pid)
    }

    static func outermostApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}
