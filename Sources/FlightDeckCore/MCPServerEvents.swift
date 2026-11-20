import Foundation
// Resource and subscription methods of MCPServer, for both eras:
//   • `resources/list`, `resources/templates/list`, `resources/read`;
//   • legacy (2025-06-18 / 2025-11-25): `resources/subscribe` / `resources/unsubscribe` on the session, with
//     `notifications/resources/updated` sent to the session's stream (stdout, or the HTTP GET SSE stream);
//   • modern (2026-07-28): `subscriptions/listen`, a long-lived request that sends
//     `notifications/subscriptions/acknowledged` and then the updates on its own stream, each tagged with
//     `_meta["io.modelcontextprotocol/subscriptionId"]` (the request's id), until the client cancels it.

extension MCPServer {
    func handleEvents(_ method: String, id: JSON, params: JSON, modern: Bool, session: MCPSession?,
                      notify: (@Sendable (JSON) -> Void)?) async -> MCPReply? {
        guard let res = resources else { return nil }
        let known = Set(res.resources.map(\.uri))
        func unknown(_ uri: String) -> MCPReply {
            // -32002 until 2025-11-25; the 2026-07-28 revision uses -32602 (clients accept both).
            MCPReply(status: 200, body: errorBody(id, modern ? Code.invalidParams : -32002, "Resource not found: \(uri). Available: \(known.sorted().joined(separator: ", "))",
                                                  data: ["uri": .str(uri)]))
        }
        switch method {
        case "resources/list":
            return ok(id, ["resources": MCPResources.listJSON(res.resources)], modern: modern)
        case "resources/templates/list":
            return ok(id, ["resourceTemplates": .array([])], modern: modern)
        case "resources/read":
            guard let uri = params["uri"]?.string else { return error(id, Code.invalidParams, "Invalid params: resources/read needs a uri", status: 200) }
            guard let text = await res.read(uri) else { return unknown(uri) }
            return ok(id, ["contents": [["uri": .str(uri), "mimeType": "application/json", "text": .str(Self.capped(text))]]], modern: modern)
        case "resources/subscribe", "resources/unsubscribe":
            guard let uri = params["uri"]?.string else { return error(id, Code.invalidParams, "Invalid params: \(method) needs a uri", status: 200) }
            guard known.contains(uri) else { return unknown(uri) }
            guard let hub = res.events else { return nil }
            guard let session else {
                return error(id, Code.invalidRequest, "Subscriptions need a session: over HTTP, send initialize, then open GET /mcp with its Mcp-Session-Id (or use subscriptions/listen, or the wait_for_event tool)", status: 200)
            }
            if method == "resources/subscribe" { session.subscribe(uri, hub: hub) } else { session.unsubscribe(uri) }
            return ok(id, [:], modern: modern)
        case "subscriptions/listen":
            guard let hub = res.events else { return nil }
            guard let notify else {
                return error(id, Code.invalidRequest, "subscriptions/listen needs a streaming transport (stdio, or HTTP POST accepting text/event-stream)", status: 200)
            }
            let asked = params["notifications"]?["resourceSubscriptions"]?.array?.compactMap(\.string) ?? []
            let uris = Set(asked.filter(known.contains))
            // Only what was asked and is supported is acknowledged; list-changed notifications never happen here.
            notify(["jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged",
                    "params": ["_meta": .object([(MCPResources.subscriptionKey, id)]),
                               "notifications": ["resourceSubscriptions": .strings(asked.filter(known.contains))]]])
            guard !uris.isEmpty else { await Self.waitForCancellation(); return MCPReply(status: 200, body: nil) }
            for await e in hub.listen() where MCPResources.wants(uris, e) {
                notify(MCPResources.updated(e, uri: MCPResources.uri(for: e, in: uris), subscription: id))
            }
            // Cancelled: a cancelled request gets no response.
            return MCPReply(status: 200, body: nil)
        default:
            return nil
        }
    }

    /// Suspends until the calling task is cancelled, without polling.
    static func waitForCancellation() async {
        let (stream, cont) = AsyncStream<Void>.makeStream()
        await withTaskCancellationHandler {
            for await _ in stream {}
        } onCancel: { cont.finish() }
    }
}
