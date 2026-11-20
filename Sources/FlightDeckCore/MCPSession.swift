import Foundation
// The one piece of per-client state the server keeps: which resources a client subscribed to (legacy
// `resources/subscribe`) and where its notifications go. stdio has one session for the process, writing to stdout;
// over HTTP a session is created by `initialize` (returned as `Mcp-Session-Id`) and its notifications go to the GET
// SSE stream the client opens with that id, buffered briefly until it does. Everything else stays stateless.

public final class MCPSession: @unchecked Sendable {
    public let id: String
    /// Claude Code channel mode (`--mcp --channel`): events go out as `notifications/claude/channel` to every
    /// subscription-less session, and `initialize` declares the `claude/channel` capability.
    public let channel: Bool
    /// Notifications kept while no stream is attached (HTTP before the GET stream opens, or between reconnects).
    static let maxPending = 50

    private let lock = NSLock()
    private var uris: Set<String> = []
    private var sink: (@Sendable (JSON) -> Void)?
    private var pending: [JSON] = []
    private var pump: Task<Void, Never>?
    private var hub: MCPEventHub?
    private var grace: Task<Void, Never>?
    var lastUsed = Date()
    /// HTTP sessions: with subscriptions but no stream open for this long, stop listening, so a client that went
    /// away without DELETE doesn't keep the watcher running. Opening a stream again resumes. nil for stdio.
    let streamGrace: TimeInterval?

    public init(id: String = UUID().uuidString, channel: Bool = false, streamGrace: TimeInterval? = nil) {
        self.id = id; self.channel = channel; self.streamGrace = streamGrace
    }

    /// Whether this session is listening to the hub now.
    public var isListening: Bool { lock.withLock { pump != nil } }

    public var subscriptions: Set<String> { lock.withLock { uris } }
    public var hasStream: Bool { lock.withLock { sink != nil } }

    /// Where notifications go from now on (nil detaches); anything buffered is sent first.
    public func attach(_ s: (@Sendable (JSON) -> Void)?) {
        let flush: [JSON] = lock.withLock {
            sink = s
            guard s != nil else { return [] }
            defer { pending = [] }
            return pending
        }
        for j in flush { s?(j) }
        guard s != nil else { return scheduleGrace() }
        let resume: MCPEventHub? = lock.withLock {
            grace?.cancel(); grace = nil
            return !uris.isEmpty && pump == nil ? hub : nil
        }
        if let resume { startPump(resume) }
    }

    /// Stops listening after `streamGrace` unless a stream is attached by then.
    private func scheduleGrace() {
        guard let g = streamGrace else { return }
        let t = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(g * 1e9))
            guard !Task.isCancelled, let self else { return }
            let stop: Task<Void, Never>? = self.lock.withLock {
                guard self.sink == nil else { return nil }
                defer { self.pump = nil }
                return self.pump
            }
            stop?.cancel()
        }
        let old: Task<Void, Never>? = lock.withLock { defer { grace = t }; return grace }
        old?.cancel()
    }

    func send(_ j: JSON) {
        let s: (@Sendable (JSON) -> Void)? = lock.withLock {
            if sink == nil { pending.append(j); if pending.count > Self.maxPending { pending.removeFirst() } }
            return sink
        }
        s?(j)
    }

    /// Adds a subscription; the first one starts listening to `hub`.
    func subscribe(_ uri: String, hub: MCPEventHub) {
        let (start, noStream): (Bool, Bool) = lock.withLock { uris.insert(uri); self.hub = hub; return (pump == nil, sink == nil) }
        if start { startPump(hub) }
        if start && noStream { scheduleGrace() }
    }

    /// Removes a subscription; with none left, stops listening (the hub stops watching if nobody else listens).
    func unsubscribe(_ uri: String) {
        let stop: Task<Void, Never>? = lock.withLock {
            uris.remove(uri)
            guard uris.isEmpty, !channel else { return nil }
            defer { pump = nil }
            return pump
        }
        stop?.cancel()
    }

    /// Channel mode listens for the whole session.
    public func startChannel(hub: MCPEventHub) {
        let start: Bool = lock.withLock { channel && pump == nil }
        if start { startPump(hub) }
    }

    private func startPump(_ hub: MCPEventHub) {
        let stream = hub.listen()
        let t = Task { [weak self] in
            for await e in stream {
                guard let self else { return }
                let subs = self.subscriptions
                if MCPResources.wants(subs, e) { self.send(MCPResources.updated(e, uri: MCPResources.uri(for: e, in: subs))) }
                if self.channel { self.send(MCPResources.channel(e)) }
            }
        }
        let keep: Bool = lock.withLock {
            guard pump == nil else { return false }
            pump = t
            return true
        }
        if !keep { t.cancel() }
    }

    /// Ends the session: no more notifications, and its listener is released.
    public func close() {
        let t: [Task<Void, Never>?] = lock.withLock { uris = []; sink = nil; pending = []; defer { pump = nil; grace = nil }; return [pump, grace] }
        for x in t { x?.cancel() }
    }
}

/// HTTP sessions by id, capped so clients that never send DELETE can't grow it without bound.
final class MCPSessionTable: @unchecked Sendable {
    static let max = 32
    static let streamGrace: TimeInterval = 300
    private let lock = NSLock()
    private var table: [String: MCPSession] = [:]

    func create() -> MCPSession {
        let s = MCPSession(streamGrace: MCPSessionTable.streamGrace)
        let evicted: [MCPSession] = lock.withLock {
            table[s.id] = s
            guard table.count > Self.max else { return [] }
            // Drop the least recently used sessions without an open stream.
            let idle = table.values.filter { !$0.hasStream && $0 !== s }.sorted { $0.lastUsed < $1.lastUsed }
            let drop = idle.prefix(table.count - Self.max)
            for d in drop { table[d.id] = nil }
            return Array(drop)
        }
        for e in evicted { e.close() }
        return s
    }

    func find(_ id: String) -> MCPSession? { lock.withLock { let s = table[id]; s?.lastUsed = Date(); return s } }

    func remove(_ id: String) -> Bool {
        let s: MCPSession? = lock.withLock { table.removeValue(forKey: id) }
        s?.close()
        return s != nil
    }
}
