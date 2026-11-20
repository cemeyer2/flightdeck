import Foundation
// The stdio loop: requests are handled concurrently (a 10-minute `wait_for_event` or a `subscriptions/listen` stream
// must not hold up other calls), replies and notifications are written whole, one per line, under a lock, and
// `notifications/cancelled` cancels the request it names.
//
// Subscriptions are served here, whichever server answers the other messages: `resources/subscribe` and
// `subscriptions/listen` go to a relay whose hub, while someone listens, follows the app's own event stream (a
// `subscriptions/listen` POST to its HTTP endpoint) or, when the app isn't reachable, the standalone server's hub.

extension MCPStdio {
    /// Methods the relay answers in place of the app or the standalone server.
    static let relayMethods: Set<String> = ["resources/subscribe", "resources/unsubscribe", "subscriptions/listen"]

    /// Reads messages from stdin until it closes, answering each on stdout. `app` is re-read for every message so a
    /// change in Settings takes effect without restarting the client. `channel` turns on Claude Code channel events.
    /// Returns when stdin reaches end of file and the requests in flight are answered.
    public static func run(app: @escaping @Sendable () -> AppEndpoint?, standalone: @escaping @Sendable () -> MCPServer, channel: Bool = false) async {
        let out = LineWriter()
        let state = State(standalone: standalone)
        let session = MCPSession(id: "stdio", channel: channel)
        session.attach { out.write($0.data) }
        let hub = MCPEventHub(upstream: { await upstreamEvents(app: app, state: state) })
        let relay = MCPServer(version: "relay", instructions: "", tools: RelayTools(events: hub))
        if channel { session.startChannel(hub: hub) }
        let notify: @Sendable (JSON) -> Void = { out.write($0.data) }
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let msg = Data(line.utf8)
                let j = try? JSON.parse(msg)
                let method = j?["method"]?.string ?? ""
                if method == "notifications/cancelled" {
                    if let rid = j?["params"]?["requestId"] { state.cancel(rid.text) }
                    continue
                }
                let key = j?["id"]?.text
                let task = Task {
                    var reply: Data?
                    if relayMethods.contains(method) {
                        reply = await relay.handle(msg, session: session, notify: notify).body?.data
                    } else {
                        reply = await answer(msg, app: app, state: state, session: session, long: isWait(j))
                    }
                    if channel, method == "initialize", let r = reply, let p = try? JSON.parse(r) { reply = withChannelCapability(p).data }
                    if let reply { out.write(reply) }
                    if let key { state.finished(key) }
                }
                if let key { state.started(key, task, streaming: method == "subscriptions/listen") }
            }
        } catch {
            FileHandle.standardError.write(Data("flightdeck --mcp: stdin: \(error.localizedDescription)\n".utf8))
        }
        // The client is gone: streams end, requests in flight are still answered (a client may close stdin early).
        session.close()
        for t in state.drain() { await t.value }
    }

    /// One message, to the app if it answers, else to the standalone server. nil for an accepted notification.
    static func answer(_ msg: Data, app: () -> AppEndpoint?, state: State, session: MCPSession, long: Bool) async -> Data? {
        if let ep = app(), let r = await forward(msg, to: ep, long: long) {
            state.note("app", "using the FlightDeck app at \(ep.url.absoluteString)")
            return r
        }
        state.note("standalone", "the FlightDeck app's MCP server isn't reachable; running standalone")
        return await state.local().handle(msg, session: session).body?.data
    }

    static func isWait(_ j: JSON?) -> Bool { j?["method"]?.string == "tools/call" && j?["params"]?["name"]?.string == "wait_for_event" }

    /// `initialize`'s reply with `experimental["claude/channel"]` in its capabilities (the app doesn't know about channel mode).
    static func withChannelCapability(_ reply: JSON) -> JSON {
        guard case .object(var top) = reply, let ri = top.firstIndex(where: { $0.0 == "result" }), case .object(var res) = top[ri].1,
              let ci = res.firstIndex(where: { $0.0 == "capabilities" }), case .object(var caps) = res[ci].1 else { return reply }
        guard !caps.contains(where: { $0.0 == "experimental" }) else { return reply }
        caps.append(("experimental", ["claude/channel": .object([])]))
        res[ci].1 = .object(caps); top[ri].1 = .object(res)
        return .object(top)
    }

    /// Events for the relay: the app's stream if it is reachable, else the standalone server's hub. The relay calls
    /// this again when the stream ends (the app quit), so it switches back and forth with the app.
    static func upstreamEvents(app: () -> AppEndpoint?, state: State) async -> AsyncStream<MCPEvent> {
        if let ep = app(), let s = await appEvents(ep) { return s }
        guard let hub = state.local().resources?.events else { return AsyncStream { $0.finish() } }
        return hub.listen()
    }

    /// The tool provider behind the relay: no tools, the fixed resource list, and the relay's hub.
    struct RelayTools: MCPToolProvider, MCPResourceProvider {
        let events: MCPEventHub?
        var specs: [MCPToolSpec] { [] }
        func call(_ name: String, arguments: JSON) async -> MCPToolResult { .error("not here") }
        var resources: [MCPResourceSpec] { MCPResources.all }
        func read(_ uri: String) async -> String? { nil }
    }

    /// Writes whole lines to stdout, one writer at a time.
    final class LineWriter: @unchecked Sendable {
        private let lock = NSLock()
        func write(_ d: Data) {
            var d = d; d.append(0x0A)
            lock.withLock { FileHandle.standardOutput.write(d) }
        }
    }

    /// Requests in flight, the standalone server (made on first use) and the last mode noted on stderr.
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let make: @Sendable () -> MCPServer
        private var server: MCPServer?
        private var tasks: [String: (Task<Void, Never>, Bool)] = [:]
        private var mode: String?
        init(standalone: @escaping @Sendable () -> MCPServer) { make = standalone }

        func local() -> MCPServer { lock.withLock { if server == nil { server = make() }; return server! } }
        func started(_ key: String, _ t: Task<Void, Never>, streaming: Bool) { lock.withLock { tasks[key] = (t, streaming) } }
        func finished(_ key: String) { lock.withLock { tasks[key] = nil } }
        func cancel(_ key: String) { lock.withLock { tasks[key]?.0 }?.cancel() }
        /// Cancels the streams and returns every task still running.
        func drain() -> [Task<Void, Never>] {
            let all = lock.withLock { Array(tasks.values) }
            for (t, streaming) in all where streaming { t.cancel() }
            return all.map(\.0)
        }
        func note(_ m: String, _ text: String) {
            let changed: Bool = lock.withLock { defer { mode = m }; return mode != m }
            if changed { FileHandle.standardError.write(Data("flightdeck --mcp: \(text)\n".utf8)) }
        }
    }
}
