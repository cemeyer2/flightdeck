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

    /// Reads messages from stdin until it closes, answering each on stdout. `app` is re-read for every message so a
    /// change in Settings takes effect without restarting the client. Returns when stdin reaches end of file.
    public static func run(app: @escaping @Sendable () -> AppEndpoint?, standalone: @escaping @Sendable () -> MCPServer) async {
        let out = FileHandle.standardOutput
        var local: MCPServer?
        var lastMode: String?
        func note(_ mode: String, _ text: String) {
            guard mode != lastMode else { return }
            lastMode = mode
            FileHandle.standardError.write(Data("flightdeck --mcp: \(text)\n".utf8))
        }
        do {
            // Messages are handled one at a time, in order; a slow tool (sample_stacks) delays the next reply, which
            // clients tolerate, and keeps stdout writes from interleaving.
            for try await line in FileHandle.standardInput.bytes.lines {
                let msg = Data(line.utf8)
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                var reply: Data??
                if let ep = app() {
                    reply = await forward(msg, to: ep)
                    if reply != nil { note("app", "using the FlightDeck app at \(ep.url.absoluteString)") }
                }
                if reply == nil {
                    note("standalone", "the FlightDeck app's MCP server isn't reachable; running standalone")
                    if local == nil { local = standalone() }
                    reply = await local!.handle(msg).body.map(\.data)
                }
                if case .some(.some(var d)) = reply {
                    d.append(0x0A)
                    out.write(d)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("flightdeck --mcp: stdin: \(error.localizedDescription)\n".utf8))
        }
    }

    /// Sends one message to the app. Returns nil when the app's server can't answer it (not listening, refused the
    /// token, not an MCP server), so the caller answers it locally; `.some(nil)` for an accepted notification.
    static func forward(_ msg: Data, to ep: AppEndpoint) async -> Data?? {
        var req = URLRequest(url: ep.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.httpBody = msg
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(ep.token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 202 { return .some(nil) }
        // Refusals by the gate (token, origin, method) mean "not usable", not an MCP answer to pass on.
        if [401, 403, 405, 503].contains(http.statusCode) { return nil }
        guard let j = try? JSON.parse(data), j["jsonrpc"] != nil else { return nil }
        return .some(j.data)   // re-serialised: guaranteed to be one line
    }

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
