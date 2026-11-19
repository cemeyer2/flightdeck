import Foundation
// Turns successive observations of the camera and microphone (CameraMicTypes.swift) into sessions: one per app per
// sensor kind, opened when the app starts using it and closed when it stops. Pure and clock-free (times come in with
// each observation), so it's tested with scripted observations (CameraMicTests). Not thread-safe: CameraMicWatch
// calls it on its own queue.
//
// Attribution, most trusted first:
//   1. macOS's privacy indicator (Control Center's log) names the app: confirmed.
//   2. Microphone only: CoreAudio says a process is reading a real input device: confirmed, with the PID. When the
//      indicator names an app and the reading process is an Apple daemon (FaceTime records through avconferenced),
//      the daemon is the app's helper, not a second app.
//   3. Nothing names the app: the session is "unknown app", or "likely X" when an app was in front as the device
//      turned on. That guess is labelled as one everywhere and never counts as an app's first use.
// The indicator's log can arrive a moment after the device turns on, so an unknown session that gets a name within
// `grace` seconds is renamed rather than recorded as two sessions.

public final class CameraMicTracker {
    /// A session starting after this long without keyboard or mouse input counts as "while idle".
    public static let idleThreshold: TimeInterval = 300
    /// An unknown-app session named within this many seconds of starting takes the name (the log was just late).
    public var grace: TimeInterval = 10
    /// A session that stops and restarts within this many seconds stays one session (indicators blink on handover).
    public var rejoin: TimeInterval = 5
    /// Fills in an app's name and path from what the observation had: (bundle ID, PID, display name).
    /// The default makes no system calls (tests); CameraMicWatch passes one that asks the system.
    public var resolve: (String?, Int32?, String?) -> SensorApp = { bundle, pid, name in
        SensorApp(name: name ?? bundle ?? pid.map { "pid \($0)" } ?? "Unknown app", bundleID: bundle, pid: pid)
    }

    /// Open sessions by `key(kind, appKey)`.
    public private(set) var open: [String: SensorSession] = [:]
    /// Recently closed sessions by key, for `rejoin`.
    private var closed: [String: SensorSession] = [:]
    /// "kind|appKey" for every app ever seen (confirmed) using each kind; drives `firstUse`.
    public private(set) var known: Set<String>
    /// False until the first observation: anything in use then was already in use when watching began.
    private var started = false

    public init(known: Set<String> = []) { self.known = known }

    static func key(_ kind: SensorKind, _ appKey: String?) -> String { kind.rawValue + "|" + (appKey ?? "?") }
    public static func knownKey(_ kind: SensorKind, _ app: SensorApp) -> String { kind.rawValue + "|" + app.key }

    /// What should be open for one kind right now.
    struct Want { var key: String; var app: SensorApp?; var confidence: AttributionConfidence; var how: String; var devices: [String] }

    func wants(_ kind: SensorKind, _ o: SensorObservation) -> [Want] {
        let devices = (o.running[kind] ?? []).map(\.label)
        let named = uniqued((o.indicator ?? []).filter { $0.kind == kind })
        var clients = kind == .microphone ? o.audioClients : []
        guard !devices.isEmpty || !named.isEmpty || !clients.isEmpty else { return [] }
        var out: [Want] = []
        for a in named {
            // The process CoreAudio sees reading the input, if it's this app (same bundle ID).
            let mine = clients.filter { $0.bundleID == a.bundleID }
            clients.removeAll { $0.bundleID == a.bundleID }
            let app = resolve(a.bundleID, mine.first?.pid, a.name)
            let devs = mine.isEmpty ? devices : Array(Set(mine.flatMap(\.devices))).sorted()
            out.append(Want(key: Self.key(kind, app.key), app: app, confidence: .confirmed,
                            how: "Named by macOS's \(kind.noun) indicator", devices: devs))
        }
        for c in clients {
            if !out.isEmpty, (c.bundleID ?? "").hasPrefix("com.apple.") {
                // An Apple daemon recording on behalf of the app the indicator named.
                out[0].how += "; recording through \(c.bundleID ?? "pid \(c.pid)")"
                out[0].devices = Array(Set(out[0].devices + c.devices)).sorted()
                continue
            }
            let app = resolve(c.bundleID, c.pid, nil)
            out.append(Want(key: Self.key(kind, app.key), app: app, confidence: .confirmed,
                            how: "CoreAudio: this process is reading the input", devices: c.devices))
        }
        if out.isEmpty {
            let why = o.indicator == nil ? "macOS's privacy indicator couldn't be read" : "macOS's privacy indicator didn't name an app"
            if let f = o.frontmost {
                out.append(Want(key: Self.key(kind, nil), app: f, confidence: .likely,
                                how: "Guess: the app in front when the \(kind.noun) turned on (\(why))", devices: devices))
            } else {
                out.append(Want(key: Self.key(kind, nil), app: nil, confidence: .unknown, how: "Unknown app: \(why)", devices: devices))
            }
        }
        return out
    }

    private func uniqued(_ a: [IndicatorAttribution]) -> [IndicatorAttribution] {
        var seen = Set<String>()
        return a.filter { seen.insert($0.bundleID).inserted }
    }

    /// Applies an observation; returns every session that was opened, changed or closed (for the store to upsert).
    @discardableResult
    public func update(_ o: SensorObservation, at t: Date) -> [SensorSession] {
        defer { started = true }
        closed = closed.filter { t.timeIntervalSince($0.value.end ?? t) <= rejoin }
        var changed: [SensorSession] = []
        for kind in SensorKind.allCases {
            let want = wants(kind, o)
            let wantKeys = Set(want.map(\.key))
            let unknownKey = Self.key(kind, nil)
            for w in want {
                if var s = open[w.key] {
                    // Still in use: note the devices and the confirmation time; fill in a PID the first sighting lacked.
                    s.devices = Array(Set(s.devices + w.devices)).sorted()
                    s.lastSeen = t
                    if s.app?.pid == nil, let pid = w.app?.pid { s.app?.pid = pid; if s.app?.path == nil { s.app?.path = w.app?.path } }
                    open[w.key] = s; changed.append(s)
                } else if var s = closed.removeValue(forKey: w.key) {
                    s.end = nil; s.lastSeen = t; s.devices = Array(Set(s.devices + w.devices)).sorted()
                    open[w.key] = s; changed.append(s)
                } else if w.key != unknownKey, var s = open[unknownKey], !wantKeys.contains(unknownKey),
                          t.timeIntervalSince(s.start) <= grace {
                    // The name arrived just after the device turned on: the unknown session was this app all along.
                    open[unknownKey] = nil
                    s.app = w.app; s.confidence = w.confidence; s.how = w.how; s.lastSeen = t
                    s.devices = Array(Set(s.devices + w.devices)).sorted()
                    s.firstUse = noteFirstUse(kind, w)
                    open[w.key] = s; changed.append(s)
                } else {
                    let s = SensorSession(kind: kind, devices: w.devices, app: w.app, confidence: w.confidence, how: w.how, start: t,
                                          startObserved: started, firstUse: noteFirstUse(kind, w),
                                          whileLocked: o.screenLocked, whileIdle: o.idleSeconds >= Self.idleThreshold)
                    open[w.key] = s; changed.append(s)
                }
            }
            // Anything of this kind no longer wanted has ended.
            for (k, var s) in open where s.kind == kind && !wantKeys.contains(k) {
                open[k] = nil
                s.end = t; s.lastSeen = t
                closed[k] = s; changed.append(s)
            }
        }
        return changed
    }

    /// True (and remembered) the first time a confirmed app uses this kind. Guesses and unknowns never count, and an
    /// app already using the device when watching began isn't "new" either: it may have used it many times before.
    private func noteFirstUse(_ kind: SensorKind, _ w: Want) -> Bool {
        guard w.confidence == .confirmed, let app = w.app else { return false }
        let new = known.insert(Self.knownKey(kind, app)).inserted
        return new && started
    }

    /// Closes everything (FlightDeck is stopping). The end is then "at least until", so `endObserved` is false.
    public func closeAll(at t: Date) -> [SensorSession] {
        let out = open.values.map { s -> SensorSession in var s = s; s.end = t; s.lastSeen = t; s.endObserved = false; return s }
        open = [:]; closed = [:]
        return out
    }

    /// Forgets every app seen before (after the user clears the history).
    public func forgetKnown() { known = [] }
}
