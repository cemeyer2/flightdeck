import Foundation

/// Always-on rolling recorder. Two independent tiers, each a series of segment files (every segment is
/// an ordinary `Trace`, so it can be opened and replayed like any recording):
/// - fine: every sample, kept for `fineRetention`
/// - coarse: one sample per `coarseEvery` seconds, kept for `coarseRetention`
/// Gaps (paused sampling, app not running) are simply missing frames, so replay draws them as breaks.
public final class BlackBox: @unchecked Sendable {
    public struct Config: Sendable {
        public var fineRetention: TimeInterval = 3600
        public var coarseRetention: TimeInterval = 86_400
        public var coarseEvery: TimeInterval = 10
        public var fineSegment: TimeInterval = 60
        public var coarseSegment: TimeInterval = 600
        public var maxBytes: UInt64 = 50 * 1_048_576
        public var keepProcesses = 25
        public init() {}
    }
    public enum Tier: String, Sendable { case fine, coarse }

    public let dir: URL
    public let config: Config
    private var pending: [Tier: [Snapshot]] = [.fine: [], .coarse: []]
    private var pendingInterval: [Tier: Double] = [.fine: 1, .coarse: 10]
    private var lastCoarse: Date?
    private let lock = NSLock()

    public init(dir: URL, config: Config = Config()) {
        self.dir = dir; self.config = config
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flightdeck/BlackBox", isDirectory: true)   // folder name predates the FlightDeck capitalisation; kept so data survives
    }

    /// Call from a background queue: may write a segment file.
    public func append(_ s: Snapshot, interval: Double) {
        let slim = Trace.trimmed(s, keep: config.keepProcesses)
        var toWrite: [(Tier, [Snapshot], Double)] = []
        lock.lock()
        pending[.fine, default: []].append(slim); pendingInterval[.fine] = interval
        if lastCoarse.map({ s.time.timeIntervalSince($0) >= config.coarseEvery - interval / 2 }) ?? true {
            pending[.coarse, default: []].append(slim); lastCoarse = s.time
            pendingInterval[.coarse] = max(config.coarseEvery, interval)
        }
        for (tier, length) in [(Tier.fine, config.fineSegment), (.coarse, config.coarseSegment)] {
            if let f = pending[tier]?.first, s.time.timeIntervalSince(f.time) >= length {
                toWrite.append((tier, pending[tier]!, pendingInterval[tier]!)); pending[tier] = []
            }
        }
        lock.unlock()
        for (tier, frames, iv) in toWrite { write(tier, frames, interval: iv) }
        if !toWrite.isEmpty { prune() }
    }

    /// Writes whatever is buffered (e.g. at quit).
    public func flush() {
        lock.lock(); let snap = pending; let iv = pendingInterval
        pending = [.fine: [], .coarse: []]; lock.unlock()
        for (tier, frames) in snap where !frames.isEmpty { write(tier, frames, interval: iv[tier] ?? 1) }
    }

    private func write(_ tier: Tier, _ frames: [Snapshot], interval: Double) {
        guard let a = frames.first?.time, let b = frames.last?.time else { return }
        let name = "\(tier.rawValue)-\(Int64(a.timeIntervalSince1970 * 1000))-\(Int64(b.timeIntervalSince1970 * 1000)).\(Trace.fileExtension)"
        let t = Trace(host: Host.current().localizedName ?? "Mac", model: Sysctl.string("hw.model") ?? "", interval: interval, frames: frames)
        try? t.write(to: dir.appendingPathComponent(name))
    }

    public struct Segment: Sendable { public var url: URL; public var tier: Tier; public var start: Date; public var end: Date; public var bytes: UInt64 }

    public func segments() -> [Segment] {
        let keys: [URLResourceKey] = [.fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { u in
            let parts = u.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.count == 3, let tier = Tier(rawValue: String(parts[0])),
                  let a = Double(parts[1]), let b = Double(parts[2]) else { return nil }
            let size = (try? u.resourceValues(forKeys: Set(keys)).fileSize).flatMap { $0 } ?? 0
            return Segment(url: u, tier: tier, start: Date(timeIntervalSince1970: a / 1000), end: Date(timeIntervalSince1970: b / 1000), bytes: UInt64(size))
        }.sorted { $0.start < $1.start }
    }

    public var diskUsage: UInt64 { segments().reduce(0) { $0 + $1.bytes } }

    /// Deletes segments past retention, then the oldest coarse/fine segments until under `maxBytes`.
    public func prune(now: Date = Date()) {
        var segs = segments()
        for s in segs where now.timeIntervalSince(s.end) > (s.tier == .fine ? config.fineRetention : config.coarseRetention) {
            try? FileManager.default.removeItem(at: s.url)
        }
        segs = segments()
        var total = segs.reduce(0) { $0 + $1.bytes }
        for s in segs where total > config.maxBytes {
            try? FileManager.default.removeItem(at: s.url); total -= s.bytes
        }
    }

    public func clear() {
        lock.lock(); pending = [.fine: [], .coarse: []]; lastCoarse = nil; lock.unlock()
        for s in segments() { try? FileManager.default.removeItem(at: s.url) }
    }

    /// All frames of one tier in [from, to], including unflushed ones. Returns nil if there are none.
    public func trace(_ tier: Tier, from: Date, to: Date = Date()) -> Trace? {
        let from = from.addingTimeInterval(-0.001), to = to.addingTimeInterval(0.001)   // dates round-trip as Double
        var frames: [Snapshot] = []
        var interval = tier == .fine ? 0.0 : config.coarseEvery
        var host = Host.current().localizedName ?? "Mac", model = ""
        for s in segments() where s.tier == tier && s.end.addingTimeInterval(1) >= from && s.start.addingTimeInterval(-1) <= to {
            guard let t = try? Trace.read(from: s.url) else { continue }
            frames += t.frames.filter { $0.time >= from && $0.time <= to }
            interval = max(interval, t.interval); host = t.host; model = t.model
        }
        lock.lock(); let mem = pending[tier] ?? []; let iv = pendingInterval[tier] ?? 1; lock.unlock()
        frames += mem.filter { $0.time >= from && $0.time <= to }
        interval = max(interval, iv)
        frames.sort { $0.time < $1.time }
        guard !frames.isEmpty else { return nil }
        return Trace(host: host, model: model, interval: interval, frames: frames)
    }
}
