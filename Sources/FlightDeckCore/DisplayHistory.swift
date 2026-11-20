import Foundation
import CoreGraphics
// This session's display connects, disconnects and mode changes, from CGDisplayRegisterReconfigurationCallback.
// The callback costs nothing between changes (no polling); it is registered once at launch by the app (the page
// itself reloads on NSApplication.didChangeScreenParametersNotification while visible). Each change
// is turned into events by comparing the display's state before and after (`events(…)`, pure, tested). Kept in
// memory only, capped at 200 events.

public final class DisplayHistory: @unchecked Sendable {
    /// What is remembered about a display between callbacks.
    public struct State: Hashable, Sendable {
        public var name: String
        /// "3840 × 2160 at 60 Hz" (DisplayModeInfo.summary of the current mode).
        public var mode: String
        public var main: Bool
        public init(name: String, mode: String, main: Bool) { self.name = name; self.mode = mode; self.main = main }
    }

    public static let shared = DisplayHistory()
    public static let limit = 200

    private let lock = NSLock()
    private var events: [DisplayEvent] = []
    private var states: [UInt32: State] = [:]
    /// Display names learned from collected reports (the callback itself only has CoreGraphics' facts).
    private var names: [UInt32: String] = [:]
    private var started = false

    public init() {}

    public var all: [DisplayEvent] { lock.withLock { events } }

    /// Records the displays present now as the session's starting point.
    public func baseline(_ now: [UInt32: State], at time: Date) {
        lock.withLock {
            states = now
            events = now.sorted { $0.key < $1.key }.map { DisplayEvent(time: time, display: $0.key, name: $0.value.name, kind: .baseline, detail: $0.value.mode) }
        }
    }

    public func learnNames(_ n: [UInt32: String]) { lock.withLock { names.merge(n) { _, new in new } } }

    /// Applies one reconfiguration callback. `after` is nil once the display is gone.
    public func note(flags: UInt32, display: UInt32, after: State?, at time: Date) {
        lock.withLock {
            var a = after
            if let known = names[display], a != nil { a?.name = known }
            let new = Self.events(flags: flags, display: display, before: states[display], after: a, at: time)
            states[display] = a
            events.append(contentsOf: new)
            if events.count > Self.limit { events.removeFirst(events.count - Self.limit) }
        }
    }

    /// Events for one callback. Begin-configuration callbacks (flag 1) are ignored: the change follows.
    public static func events(flags: UInt32, display: UInt32, before: State?, after: State?, at time: Date) -> [DisplayEvent] {
        let f = CGDisplayChangeSummaryFlags(rawValue: flags)
        guard !f.contains(.beginConfigurationFlag) else { return [] }
        let name = after?.name ?? before?.name ?? "Display \(display)"
        func ev(_ k: DisplayEvent.Kind, _ detail: String) -> DisplayEvent { DisplayEvent(time: time, display: display, name: name, kind: k, detail: detail) }
        var out: [DisplayEvent] = []
        if f.contains(.removeFlag) { return [ev(.disconnected, before?.mode ?? "")] }
        if f.contains(.addFlag) || (before == nil && after != nil) { out.append(ev(.connected, after?.mode ?? "")) }
        else if let b = before, let a = after, b.mode != a.mode { out.append(ev(.modeChanged, "\(b.mode) → \(a.mode)")) }
        if f.contains(.disabledFlag) { out.append(ev(.disabled, "")) }
        if f.contains(.enabledFlag) && !f.contains(.addFlag) { out.append(ev(.enabled, after?.mode ?? "")) }
        if f.contains(.setMainFlag), after?.main == true, before?.main != true { out.append(ev(.mainChanged, "")) }
        if f.contains(.mirrorFlag) { out.append(ev(.mirroring, "now mirroring")) }
        if f.contains(.unMirrorFlag) { out.append(ev(.mirroring, "no longer mirroring")) }
        return out
    }

    // MARK: Live

    /// Registers the reconfiguration callback once and records the displays present now. Main thread.
    public func start() {
        let first = lock.withLock { () -> Bool in defer { started = true }; return !started }
        guard first else { return }
        var now: [UInt32: State] = [:]
        for id in DisplayCollector.onlineIDs() { if let s = Self.state(of: id) { now[id] = s } }
        baseline(now, at: Date())
        CGDisplayRegisterReconfigurationCallback({ display, flags, _ in
            let h = DisplayHistory.shared
            h.note(flags: flags.rawValue, display: display, after: flags.contains(.removeFlag) ? nil : DisplayHistory.state(of: display), at: Date())
        }, nil)
    }

    /// CoreGraphics' view of a display, cheap enough for the callback.
    static func state(of id: CGDirectDisplayID) -> State? {
        guard let m = CGDisplayCopyDisplayMode(id) else { return nil }
        let mode = DisplayModeInfo(width: m.width, height: m.height, pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight, refreshHz: m.refreshRate)
        let name = CGDisplayIsBuiltin(id) != 0 ? "Built-in display" : "External display"
        return State(name: name, mode: mode.summary, main: CGDisplayIsMain(id) != 0)
    }
}
