import Foundation
// Fans events out to everyone listening: resource subscribers, `subscriptions/listen` streams, Claude Code channels
// and `wait_for_event` calls. A watcher polls the feed (cached state the server serves anyway) and diffs it with
// MCPEventDetector, but only while at least one listener exists: with nobody listening there is no task, timer or
// read at all. Clock and sleep are injectable so tests run instantly.

public final class MCPEventHub: @unchecked Sendable {
    public typealias Feed = @Sendable () async -> MCPWatchState?
    /// What the watcher does while someone listens: poll a feed, or relay another hub's events (the stdio proxy).
    let run: @Sendable (MCPEventHub) async -> Void
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Events kept for `flightdeck://events` and `wait_for_event`'s `after_seq`.
    public static let keep = 100

    private let lock = NSLock()
    private var listeners: [Int: AsyncStream<MCPEvent>.Continuation] = [:]
    private var nextID = 0, seq = 0
    private var recent: [MCPEvent] = []
    private var watcher: Task<Void, Never>?

    public init(interval: TimeInterval, now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                feed: @escaping Feed) {
        self.now = now; self.sleep = sleep
        run = { hub in
            var detector = MCPEventDetector()
            while !Task.isCancelled {
                if let s = await feed() {
                    for e in detector.update(s, now: now()) where !Task.isCancelled { hub.publish(e) }
                }
                do { try await sleep(interval) } catch { break }
            }
        }
    }

    /// A hub that republishes events from `upstream` while someone listens. `upstream` is called again (after
    /// `retry` seconds) whenever its stream ends, so a relay survives the other end going away and coming back.
    public init(retry: TimeInterval = 5, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                upstream: @escaping @Sendable () async -> AsyncStream<MCPEvent>) {
        now = { Date() }; self.sleep = sleep
        run = { hub in
            while !Task.isCancelled {
                for await e in await upstream() { hub.publish(e) }
                do { try await sleep(retry) } catch { break }
            }
        }
    }

    public var listenerCount: Int { lock.withLock { listeners.count } }
    public var isWatching: Bool { lock.withLock { watcher != nil } }
    public var lastSeq: Int { lock.withLock { seq } }

    /// A stream of every event from now on. The first listener starts the watcher; when the last one's stream ends
    /// (cancelled or dropped), the watcher stops.
    public func listen() -> AsyncStream<MCPEvent> {
        let (stream, cont) = AsyncStream<MCPEvent>.makeStream(bufferingPolicy: .bufferingNewest(200))
        let start: Bool = lock.withLock {
            let id = nextID; nextID += 1
            listeners[id] = cont
            cont.onTermination = { [weak self] _ in self?.remove(id) }
            return watcher == nil
        }
        if start { startWatcher() }
        return stream
    }

    private func remove(_ id: Int) {
        let stop: Task<Void, Never>? = lock.withLock {
            listeners[id] = nil
            guard listeners.isEmpty else { return nil }
            defer { watcher = nil }
            return watcher
        }
        stop?.cancel()
    }

    private func startWatcher() {
        let run = self.run
        let t = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await run(self)
        }
        let keep: Bool = lock.withLock {
            guard watcher == nil, !listeners.isEmpty else { return false }
            watcher = t
            return true
        }
        if !keep { t.cancel() }
    }

    /// Numbers the event (unless it already has a number), keeps it in the recent list and hands it to every listener. Also the test hook.
    @discardableResult public func publish(_ e: MCPEvent) -> MCPEvent {
        var e = e
        let targets: [AsyncStream<MCPEvent>.Continuation] = lock.withLock {
            // A relayed event keeps its upstream number, so seqs mean the same through the stdio proxy.
            if e.seq > 0 { seq = max(seq, e.seq) } else { seq += 1; e.seq = seq }
            recent.append(e)
            if recent.count > Self.keep { recent.removeFirst(recent.count - Self.keep) }
            return Array(listeners.values)
        }
        for c in targets { c.yield(e) }
        return e
    }

    /// Kept events newer than `seq`, oldest first.
    public func recentEvents(after seq: Int = 0) -> [MCPEvent] { lock.withLock { recent.filter { $0.seq > seq } } }

    /// The first event matching `filter`: a kept one newer than `afterSeq` if given, else the next one to happen, or
    /// nil after `timeout` seconds (or when the calling task is cancelled).
    public func wait(timeout: TimeInterval, afterSeq: Int? = nil, matching filter: @escaping @Sendable (MCPEvent) -> Bool) async -> MCPEvent? {
        let stream = listen()   // before checking the kept events, so nothing slips between the two
        if let afterSeq, let hit = recentEvents(after: afterSeq).first(where: filter) { return hit }
        let sleep = self.sleep
        return await withTaskGroup(of: MCPEvent?.self) { g in
            g.addTask { for await e in stream where filter(e) { return e }; return nil }
            g.addTask { try? await sleep(timeout); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }
}

extension MCPEventHub {
    /// A hub reading `source`: every `interval` seconds while someone listens (5 s from the app's cached state, 15 s
    /// standalone, where each poll takes a sample). macOS reports are rescanned at most once a minute.
    public static func watching(_ source: MCPDataSource, now: @escaping @Sendable () -> Date = { Date() }) -> MCPEventHub {
        let reports = ReportCache()
        return MCPEventHub(interval: source.standalone ? 15 : 5, now: now) {
            let t = now()
            async let snap = source.snapshot()
            async let findings = source.findings()
            async let incidents = source.incidents()
            var s = MCPWatchState()
            s.incidents = await incidents
            s.findings = await findings
            if let r = reports.fresh(t) { s.reports = r } else {
                let r = await source.reports(since: t.addingTimeInterval(-86_400))
                reports.store(r, t); s.reports = r
            }
            if let snap = await snap {
                s.thermalState = snap.power.thermalState
                s.batteryPercent = snap.power.battery?.percent
                s.charging = snap.power.battery.map { $0.isCharging || snap.power.powerSource == "AC Power" }
                let apps = AppUsage.aggregate(snap.processes)
                for a in apps { for p in a.pids { s.appOf[p] = a.name } }
            }
            return s
        }
    }

    final class ReportCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (Date, [DiagnosticReport])?
        func fresh(_ t: Date) -> [DiagnosticReport]? { lock.withLock { value.flatMap { t.timeIntervalSince($0.0) < 60 ? $0.1 : nil } } }
        func store(_ r: [DiagnosticReport], _ t: Date) { lock.withLock { value = (t, r) } }
    }
}
