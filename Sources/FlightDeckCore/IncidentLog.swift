import Foundation
// The "what happened" history behind the Flight Log: live `Finding`s from the Analyzer come and go every sample;
// this file turns each lasting one into an `Incident` with a start and end, and persists them as JSON.

/// A finding as it happened: when it started, when it ended, and how bad it got.
public struct Incident: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    /// The `Finding.id` it came from (e.g. "cpu:<app>", "hang:<pid>-<start>"); used to find a live finding's incident.
    public var key: String
    /// Worst severity seen while it lasted (it only ever goes up).
    public var severity: Finding.Severity
    public var icon: String
    /// Title and detail follow the latest wording of the finding (e.g. the current CPU %).
    public var title: String
    public var detail: String?
    public var destination: String?
    /// When the condition began (the finding's `since`), not when it crossed `minDuration` and was logged.
    public var start: Date
    public var end: Date?          // nil while ongoing
    /// Call stacks captured automatically while it was happening (hangs and hogs), and their one-line summary.
    public var evidencePath: String? = nil
    public var evidenceSummary: String? = nil
    /// Ongoing incidents measure up to now.
    public var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
}

/// Persistent history of findings ("what happened at 3:14 pm?"). Findings shorter than `minDuration`
/// are dropped as noise. Keeps 7 days, at most `maxCount`. Not thread-safe: the Engine confines it to its sampling
/// queue (TraceStats uses a private, file-less instance).
public final class IncidentLog {
    public private(set) var incidents: [Incident] = []
    public let url: URL?
    /// Seconds a finding must persist before it becomes an incident.
    public var minDuration: TimeInterval = 20
    public var retention: TimeInterval = 7 * 86_400
    public var maxCount = 1000
    /// Findings that are usually intentional (e.g. an app keeping the Mac awake) aren't incidents.
    public var excludedPrefixes = ["awake:"]
    private var open: [String: Int] = [:]   // finding id -> index of ongoing incident
    /// When each finding's last incident was closed. A finding that comes back (e.g. after a pause) starts a new incident
    /// no earlier than this, so incidents for the same finding never overlap.
    private var closedAt: [String: Date] = [:]
    /// Unsaved changes. The Engine calls `save()` about once a minute and at quit, so small edits don't each hit disk.
    private var dirty = false
    /// Bumped on every change, so callers can skip copying an unchanged log.
    public private(set) var revision = 0

    public init(url: URL?) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
            incidents = (try? dec.decode([Incident].self, from: d)) ?? []
            // Anything left open (the app crashed or was killed before `closeAll`) ended at an unknown time. It is closed at
            // its start, i.e. with zero duration, rather than guessing how long it lasted.
            for i in incidents.indices where incidents[i].end == nil { incidents[i].end = incidents[i].start }
        }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flightdeck/incidents.json")   // see BlackBox.defaultDirectory
    }

    /// Feed the current findings once per sample (`now` = the snapshot's time). Returns incidents that just became long
    /// enough to log; the Engine uses them to trigger notifications and evidence capture.
    @discardableResult
    public func update(_ findings: [Finding], at now: Date) -> [Incident] {
        var newlyLogged: [Incident] = []
        let ids = Set(findings.map(\.id))
        // A logged finding that is no longer reported has ended. (Iterating `open` while mutating it is safe: the loop
        // walks a copy.)
        for (id, idx) in open where !ids.contains(id) {
            incidents[idx].end = now; closedAt[id] = now; open[id] = nil; dirty = true; revision += 1
        }
        // Findings shorter than `minDuration` aren't logged yet; once one is, its incident is backdated to `f.since`.
        // Title/detail refreshes don't mark the log dirty or bump `revision`: they ride along with the next real change.
        for f in findings where now.timeIntervalSince(f.since) >= minDuration && !excludedPrefixes.contains(where: { f.id.hasPrefix($0) }) {
            if let idx = open[f.id] {
                if f.severity > incidents[idx].severity { incidents[idx].severity = f.severity; dirty = true; revision += 1 }
                if incidents[idx].title != f.title || incidents[idx].detail != f.detail { dirty = true; revision += 1 }
                incidents[idx].title = f.title; incidents[idx].detail = f.detail
            } else {
                let inc = Incident(id: UUID(), key: f.id, severity: f.severity, icon: f.icon, title: f.title, detail: f.detail,
                                   destination: f.destination, start: max(f.since, closedAt[f.id] ?? .distantPast), end: nil)
                incidents.append(inc); open[f.id] = incidents.count - 1; newlyLogged.append(inc); dirty = true; revision += 1
            }
        }
        // Trim with some slack (100 extra entries, or an hour past retention) so it runs occasionally, not every sample.
        if incidents.count > maxCount + 100 || (incidents.first.map { now.timeIntervalSince($0.start) > retention + 3600 } ?? false) {
            trim(now: now)
        }
        return newlyLogged
    }

    /// Ends every ongoing incident (sampling paused, app quitting, or the end of a replayed trace). If the same finding
    /// is still active on the next update it starts a new incident, backdated to the finding's `since`.
    public func closeAll(at now: Date) {
        for (id, idx) in open { incidents[idx].end = now; closedAt[id] = now }
        if !open.isEmpty { dirty = true; revision += 1 }
        open = [:]
    }

    /// Drops incidents that ended more than `retention` ago (ongoing ones are kept), then keeps the newest `maxCount`.
    /// `open` holds array indices, so it's remapped to the new positions; an open incident that got dropped is forgotten.
    private func trim(now: Date) {
        let keep = incidents.enumerated().filter { now.timeIntervalSince($0.element.end ?? now) <= retention }.suffix(maxCount)
        var remap: [Int: Int] = [:]
        for (newIdx, old) in keep.enumerated() { remap[old.offset] = newIdx }
        incidents = keep.map(\.element)
        open = open.compactMapValues { remap[$0] }
        dirty = true; revision += 1
    }

    /// Records the stack sample captured for an incident. Called back on the sampling queue when a capture finishes.
    public func attach(evidence path: String, summary: String?, to id: UUID) {
        guard let i = incidents.firstIndex(where: { $0.id == id }) else { return }
        incidents[i].evidencePath = path; incidents[i].evidenceSummary = summary
        dirty = true; revision += 1
    }

    public func clear() { incidents = []; open = [:]; dirty = true; revision += 1; save() }

    /// Writes the whole log atomically if anything changed; a no-op for in-memory logs (`url == nil`). Write errors are
    /// ignored and the log is still marked clean, so a failed save is only retried after the next change.
    public func save() {
        guard dirty, let url else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? enc.encode(incidents) { try? d.write(to: url, options: .atomic) }
        dirty = false
    }
}

/// Confined to one queue by its owner.
extension IncidentLog: @unchecked Sendable {}
