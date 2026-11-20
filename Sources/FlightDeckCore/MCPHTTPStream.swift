import Foundation
import Network
// Server-Sent Event streams on the MCP endpoint, used only for notifications:
//   • GET /mcp with `Mcp-Session-Id` (legacy revisions): the session's stream; `resources/subscribe` updates arrive here;
//   • POST /mcp of a `subscriptions/listen` request (2026-07-28): the response is the subscription's stream;
//   • DELETE /mcp with `Mcp-Session-Id` ends the session.
// A stream lasts until the client closes it. Each carries a comment line every 25 s so idle-timeouts in clients and
// proxies don't drop it; that timer exists only while a stream is open. At most `maxStreams` at once.

extension MCPHTTPServer {
    static let keepAlive: TimeInterval = 25

    /// Whether a POST body is a `subscriptions/listen` request (answered with a stream).
    static func isListen(_ body: Data) -> Bool {
        guard body.count < 64 << 10, let j = try? JSON.parse(body) else { return false }
        return j["method"]?.string == "subscriptions/listen" && j["id"] != nil
    }

    /// One SSE event carrying a JSON-RPC message.
    static func sseEvent(_ j: JSON) -> Data { Data("event: message\ndata: \(j.text)\n\n".utf8) }

    /// Runs on `queue`.
    func respondStreaming(_ c: NWConnection, method: String, headers: [String: String], body: Data) {
        let sid = headers["mcp-session-id"]
        if method == "DELETE" {
            guard let sid else { return send(c, status: 400, body: Self.errorJSON("DELETE needs an Mcp-Session-Id header")) }
            return send(c, status: server.endSession(sid) ? 200 : 404, body: nil)
        }
        if method == "GET" {
            guard headers["accept"]?.contains("text/event-stream") == true else {
                return send(c, status: 405, body: Self.errorJSON("GET /mcp opens a notification stream: send Accept: text/event-stream"), extra: [("Allow", "POST")])
            }
            guard let sid else {
                return send(c, status: 405, body: Self.errorJSON("Method not allowed: a GET stream needs the Mcp-Session-Id from initialize (or POST subscriptions/listen)"), extra: [("Allow", "POST")])
            }
            guard let session = server.session(sid) else { return send(c, status: 404, body: Self.errorJSON("Session not found: send initialize again")) }
            openStream(c) { [weak self] write in
                session.attach(write)
                await MCPServer.waitForCancellation()
                if self != nil { session.attach(nil) }
            }
            return
        }
        // subscriptions/listen
        guard headers["accept"]?.contains("text/event-stream") == true else {
            return send(c, status: 406, body: Self.errorJSON("subscriptions/listen streams its notifications: send Accept: text/event-stream"))
        }
        let server = self.server
        openStream(c) { write in
            let reply = await server.handle(body, headers: headers, notify: write)
            if let b = reply.body { write(b) }   // an error (e.g. bad params) instead of a stream
        }
    }

    /// Writes the SSE response head, then runs `body` with a writer until the client disconnects (which cancels it)
    /// or `body` returns (which closes the stream).
    private func openStream(_ c: NWConnection, _ body: @escaping @Sendable (@escaping @Sendable (JSON) -> Void) async -> Void) {
        guard streams < Self.maxStreams else {
            return send(c, status: 429, body: Self.errorJSON("Too many open notification streams (limit \(Self.maxStreams))"))
        }
        streams += 1
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let write: @Sendable (JSON) -> Void = { j in c.send(content: Self.sseEvent(j), completion: .contentProcessed { _ in }) }
        let task = Task { await body(write) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.keepAlive, repeating: Self.keepAlive)
        timer.setEventHandler { c.send(content: Data(": keep-alive\n\n".utf8), completion: .contentProcessed { _ in }) }
        timer.resume()
        let closed = StreamClosed()
        let finish: @Sendable () -> Void = { [weak self] in
            self?.queue.async {
                guard !closed.done else { return }
                closed.done = true
                timer.cancel(); task.cancel()
                self?.streams -= 1
                c.cancel()
            }
        }
        // The client closing its side (or the connection failing) ends the stream.
        func watch() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, done, err in
                if done || err != nil { finish() } else { watch() }
            }
        }
        watch()
        // `body` returning (an error reply, or the server ending it) closes the stream once its writes are out.
        Task { await task.value; c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in finish() }) }
    }

    /// Touched only on `queue`.
    private final class StreamClosed: @unchecked Sendable { var done = false }
}
