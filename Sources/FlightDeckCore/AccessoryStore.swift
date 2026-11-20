import Foundation
// Accessory battery history on disk: ~/Library/Application Support/Flightdeck/Accessories/ holds one JSON file per
// month ("2026-11.json": device name → readings). A reading is kept only when a level changed or 2 hours passed, so a
// mouse that sits at 80% for a day costs a dozen rows. Readings older than `retentionDays` are dropped when a month's
// file is rewritten and whole months past it are deleted. Nothing here leaves the Mac.
//
// `AccessoryRecorder` reads the IORegistry levels every `interval` on a background timer (no subprocess) and keeps
// the low-battery findings for the Engine.

public final class AccessoryStore: @unchecked Sendable {
    public static let retentionDays = 60
    public static var defaultDirectory: URL { DailyLog.defaultDirectory.appendingPathComponent("Accessories") }
    static let keepUnchanged: TimeInterval = 2 * 3600

    public let dir: URL?
    public let readOnly: Bool
    private let lock = NSLock()
    private var memory: [String: [String: [AccessoryReading]]] = [:]   // month -> device -> readings (dir == nil)
    private var loaded: [String: [String: [AccessoryReading]]] = [:]   // cache of files read

    public init(dir: URL?, readOnly: Bool = false) {
        self.dir = dir; self.readOnly = readOnly
        if let dir, !readOnly { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    /// An in-memory store (demo, previews, tests).
    public convenience init(preview: [String: [AccessoryReading]]) {
        self.init(dir: nil)
        for (name, rs) in preview { for r in rs { memory[month(r.time), default: [:]][name, default: []].append(r) } }
    }

    static let monthFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"; return f
    }()
    func month(_ d: Date) -> String { Self.monthFormat.string(from: d) }

    /// Unlocked: callers hold `lock`.
    private func file(_ m: String) -> [String: [AccessoryReading]] {
        guard let dir else { return memory[m] ?? [:] }
        if let c = loaded[m] { return c }
        let u = dir.appendingPathComponent(m + ".json")
        let v = (try? Data(contentsOf: u)).flatMap { try? Self.decoder.decode([String: [AccessoryReading]].self, from: $0) } ?? [:]
        loaded[m] = v
        return v
    }

    private func write(_ m: String, _ v: [String: [AccessoryReading]]) {
        guard let dir else { memory[m] = v; return }
        loaded[m] = v
        guard !readOnly, let data = try? Self.encoder.encode(v) else { return }
        try? data.write(to: dir.appendingPathComponent(m + ".json"), options: .atomic)
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    /// Every device's readings since `since`, oldest first.
    public func history(since: Date, now: Date = Date()) -> [String: [AccessoryReading]] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: [AccessoryReading]] = [:]
        var d = since
        var months: [String] = []
        while d <= now { let m = month(d); if months.last != m { months.append(m) }; d = d.addingTimeInterval(86_400 * 27) }
        if months.last != month(now) { months.append(month(now)) }
        for m in months { for (k, v) in file(m) { out[k, default: []] += v.filter { $0.time >= since } } }
        return out.mapValues { $0.sorted { $0.time < $1.time } }
    }

    /// Adds a reading unless it repeats the last one within `keepUnchanged`. Returns the previous reading and whether
    /// this one was kept.
    @discardableResult
    public func record(_ name: String, _ r: AccessoryReading) -> (previous: AccessoryReading?, kept: Bool) {
        lock.lock(); defer { lock.unlock() }
        let m = month(r.time)
        var f = file(m)
        var prev = f[name]?.last
        if prev == nil, let p = Calendar.current.date(byAdding: .month, value: -1, to: r.time) { prev = file(month(p))[name]?.last }
        if let p = prev, p.levels == r.levels, r.time.timeIntervalSince(p.time) < Self.keepUnchanged { return (p, false) }
        if let p = prev, r.time <= p.time { return (p, false) }
        let cutoff = r.time.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        f[name, default: []].append(r)
        f = f.mapValues { $0.filter { $0.time >= cutoff } }.filter { !$0.value.isEmpty }
        write(m, f)
        return (prev, true)
    }

    /// Deletes month files entirely older than the retention window.
    public func prune(now: Date = Date()) {
        guard let dir, !readOnly else { return }
        let keep = month(now.addingTimeInterval(-Double(Self.retentionDays) * 86_400))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in names where n.hasSuffix(".json") && n.count == 12 && String(n.prefix(7)) < keep {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }
}

public final class AccessoryRecorder: @unchecked Sendable {
    public static let interval: TimeInterval = 20 * 60
    public let store: AccessoryStore
    private let queue = DispatchQueue(label: "flightdeck.accessories", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var low: [String: Finding] = [:]

    public init(store: AccessoryStore) { self.store = store }

    /// Starts the IORegistry timer (first reading after a minute). Idempotent.
    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            store.prune()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 60, repeating: Self.interval, leeway: .seconds(120))
            t.setEventHandler { [weak self] in self?.record(Peripherals.hidBatteries().mapValues { ["Main": $0] }) }
            t.resume(); timer = t
        }
    }

    /// Records levels by device name (from the IORegistry timer or a Peripherals page load) and updates low findings.
    public func record(_ levels: [String: [String: Int]], now: Date = Date()) {
        for (name, l) in levels where !l.isEmpty {
            let r = AccessoryReading(time: now, levels: l)
            let (prev, kept) = store.record(name, r)
            lock.lock()
            if (l["Main"] ?? 100) >= AccessoryForecast.lowThreshold { low[name] = nil }
            else if kept, let f = AccessoryForecast.lowFinding(name: name, previous: prev, new: r) { low[name] = f }
            lock.unlock()
        }
    }

    /// Low-battery findings, each for 6 hours after it was raised.
    public func findings(now: Date = Date()) -> [Finding] {
        lock.lock(); defer { lock.unlock() }
        low = low.filter { now.timeIntervalSince($0.value.since) < 6 * 3600 }
        return low.values.sorted { $0.id < $1.id }
    }
}
