import Foundation

/// A finding as it happened: when it started, when it ended, and how bad it got.
public struct Incident: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var key: String
    public var severity: Finding.Severity
    public var icon: String
    public var title: String
    public var detail: String?
    public var destination: String?
    public var start: Date
    public var end: Date?          // nil while ongoing
    public var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
}

/// Persistent history of findings ("what happened at 3:14 pm?"). Findings shorter than `minDuration`
/// are dropped as noise. Keeps 7 days, at most `maxCount`. Not thread-safe.
public final class IncidentLog {
    public private(set) var incidents: [Incident] = []
    public let url: URL?
    public var minDuration: TimeInterval = 20
    public var retention: TimeInterval = 7 * 86_400
    public var maxCount = 1000
    private var open: [String: Int] = [:]   // finding id -> index of ongoing incident
    private var dirty = false
    /// Bumped on every change, so callers can skip copying an unchanged log.
    public private(set) var revision = 0

    public init(url: URL?) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
            incidents = (try? dec.decode([Incident].self, from: d)) ?? []
            // anything left open when the app quit ended at an unknown time; close it at its last known point
            for i in incidents.indices where incidents[i].end == nil { incidents[i].end = incidents[i].start }
        }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flightdeck/incidents.json")
    }

    /// Feed the current findings once per sample. Returns incidents that just became long enough to log.
    @discardableResult
    public func update(_ findings: [Finding], at now: Date) -> [Incident] {
        var newlyLogged: [Incident] = []
        let ids = Set(findings.map(\.id))
        for (id, idx) in open where !ids.contains(id) {
            incidents[idx].end = now; open[id] = nil; dirty = true; revision += 1
        }
        for f in findings where now.timeIntervalSince(f.since) >= minDuration {
            if let idx = open[f.id] {
                if f.severity > incidents[idx].severity { incidents[idx].severity = f.severity; dirty = true; revision += 1 }
                incidents[idx].title = f.title; incidents[idx].detail = f.detail
            } else {
                let inc = Incident(id: UUID(), key: f.id, severity: f.severity, icon: f.icon, title: f.title, detail: f.detail,
                                   destination: f.destination, start: f.since, end: nil)
                incidents.append(inc); open[f.id] = incidents.count - 1; newlyLogged.append(inc); dirty = true; revision += 1
            }
        }
        if incidents.count > maxCount + 100 || (incidents.first.map { now.timeIntervalSince($0.start) > retention + 3600 } ?? false) {
            trim(now: now)
        }
        return newlyLogged
    }

    /// Ends every ongoing incident (sampling paused, or a gap in the data).
    public func closeAll(at now: Date) {
        for (_, idx) in open { incidents[idx].end = now }
        if !open.isEmpty { dirty = true; revision += 1 }
        open = [:]
    }

    private func trim(now: Date) {
        let keep = incidents.enumerated().filter { now.timeIntervalSince($0.element.end ?? now) <= retention }.suffix(maxCount)
        var remap: [Int: Int] = [:]
        for (newIdx, old) in keep.enumerated() { remap[old.offset] = newIdx }
        incidents = keep.map(\.element)
        open = open.compactMapValues { remap[$0] }
        dirty = true; revision += 1
    }

    public func clear() { incidents = []; open = [:]; dirty = true; revision += 1; save() }

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
