import Foundation
// The stdio transport behind `FlightDeck --mcp`: an MCP client launches the binary as a subprocess and exchanges
// newline-delimited JSON-RPC messages over stdin/stdout. Only protocol messages are written to stdout; the one-line
// notes about which mode is in use go to stderr, which clients show as logs.
//
// When the FlightDeck app is running with its MCP server on, each message is forwarded to it over HTTP, so answers
// include the app's live findings, Flight Log and black box. When it isn't (app closed, server off, wrong token), the
// message is answered here by a standalone server that samples on demand. The choice is made per message, so a
// session keeps working when the app quits or starts. Both servers are stateless (see MCPServer), which is what
// makes switching mid-session safe.

public enum MCPStdio {
    /// The app's HTTP endpoint, as configured in its Settings.
    public struct AppEndpoint: Sendable {
        public var url: URL
        public var token: String
        public init(url: URL, token: String) { self.url = url; self.token = token }
    }

    /// Sends one message to the app. Returns nil when the app's server can't answer it (not listening, refused the
    /// token, not an MCP server), so the caller answers it locally; `.some(nil)` for an accepted notification.
    /// `long` is for `wait_for_event`, which may take up to 10 minutes to answer.
    static func forward(_ msg: Data, to ep: AppEndpoint, long: Bool = false) async -> Data?? {
        var req = URLRequest(url: ep.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: long ? 700 : 90)
        req.httpMethod = "POST"
        req.httpBody = msg
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(ep.token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await (long ? longSession : session).data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 202 { return .some(nil) }
        // Refusals by the gate (token, origin, method) mean "not usable", not an MCP answer to pass on.
        if [401, 403, 405, 503].contains(http.statusCode) { return nil }
        guard let j = try? JSON.parse(data), j["jsonrpc"] != nil else { return nil }
        return .some(j.data)   // re-serialised: guaranteed to be one line
    }

    /// The app's event stream: a `subscriptions/listen` POST answered with Server-Sent Events, decoded to events.
    /// nil if the app doesn't answer with a stream. The stream ends when the app closes it (or quits).
    static func appEvents(_ ep: AppEndpoint) async -> AsyncStream<MCPEvent>? {
        var req = URLRequest(url: ep.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        req.httpMethod = "POST"
        let body: JSON = ["jsonrpc": "2.0", "id": "flightdeck-stdio-relay", "method": "subscriptions/listen",
                          "params": ["_meta": [MCPServer.metaVersionKey: .str(MCPServer.modernVersions[0])],
                                     "notifications": ["resourceSubscriptions": [.str(MCPResources.events)]]]]
        req.httpBody = body.data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(MCPServer.modernVersions[0], forHTTPHeaderField: "MCP-Protocol-Version")
        req.setValue("Bearer \(ep.token)", forHTTPHeaderField: "Authorization")
        guard let (bytes, resp) = try? await longSession.bytes(for: req), let http = resp as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true else { return nil }
        let (stream, cont) = AsyncStream<MCPEvent>.makeStream()
        let reader = Task {
            do {
                for try await line in bytes.lines where line.hasPrefix("data:") {
                    guard let j = try? JSON.parse(Data(line.dropFirst(5).utf8)), let e = MCPResources.event(in: j) else { continue }
                    cont.yield(e)
                }
            } catch {}
            cont.finish()
        }
        cont.onTermination = { _ in reader.cancel() }
        return stream
    }

    /// For streams and `wait_for_event`: idle gaps up to 2 minutes (the app's streams send a keep-alive every 25 s).
    static let longSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 700
        c.timeoutIntervalForResource = 7 * 86_400
        c.waitsForConnectivity = false
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    /// Ephemeral: no cookies, cache or credentials stored. An absent app costs nothing noticeable: a refused
    /// connection on localhost fails immediately. The long timeout leaves room for slow tools (checkup).
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 90
        c.waitsForConnectivity = false
        c.connectionProxyDictionary = [:]   // never route localhost through a system proxy
        return URLSession(configuration: c)
    }()
}
