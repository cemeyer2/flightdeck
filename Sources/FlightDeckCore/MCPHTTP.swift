import Foundation
import Network
// The Streamable HTTP transport for the MCP server: `POST /mcp` with a JSON-RPC message in, one JSON response out.
// Server-to-client streams (Server-Sent Events) exist only for notifications (MCPHTTPStream.swift): the legacy GET
// stream of a session from `initialize`, and the 2026-07-28 `subscriptions/listen` POST. Bound to 127.0.0.1
// only, like MetricsServer. Every request must carry the bearer token shown in Settings, and a browser `Origin` or
// `Host` that isn't this Mac is refused, so a web page can't reach the server through DNS rebinding. Nothing runs
// between requests.

/// The checks applied to every request before its body is looked at. Pure, so tests can cover each refusal.
public enum MCPHTTPGate {
    /// Hosts that mean "this Mac". Anything else in Origin or Host is a page or name that merely resolves here.
    static let localHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// The host part of a Host header value or an Origin URL ("http://localhost:3000" → "localhost").
    static func host(of v: String) -> String {
        var s = Substring(v.trimmingCharacters(in: .whitespaces).lowercased())
        if let r = s.range(of: "://") { s = s[r.upperBound...] }
        if let slash = s.firstIndex(of: "/") { s = s[..<slash] }
        if s.hasPrefix("[") { return s.firstIndex(of: "]").map { String(s[...$0]) } ?? String(s) }   // [::1]:port
        return String(s.split(separator: ":", maxSplits: 1).first ?? "")
    }

    /// Compares in time independent of where the strings differ, so the token can't be guessed byte by byte.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) { diff |= Int((i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)) }
        return diff == 0
    }

    /// nil if the request may proceed, else the HTTP status and a message. `headers` have lowercased names.
    public static func check(method: String, path: String, headers: [String: String], token: String) -> (status: Int, message: String)? {
        // Origin first: a cross-site page must learn nothing, not even whether its token guess was right. "null" is
        // what sandboxed frames and file: pages send, so it's refused too.
        if let o = headers["origin"], !localHosts.contains(host(of: o)) { return (403, "Forbidden: requests from web pages (Origin \(o)) are not accepted") }
        if let h = headers["host"], !localHosts.contains(host(of: h)) { return (403, "Forbidden: Host must be 127.0.0.1 or localhost") }
        let p = path.split(separator: "?").first.map(String.init) ?? path
        guard p == "/mcp" || p == "/mcp/" else { return (404, "Not found: the MCP endpoint is /mcp") }
        guard !token.isEmpty else { return (503, "The MCP server has no token configured") }
        let auth = headers["authorization"] ?? ""
        let given = auth.lowercased().hasPrefix("bearer ") ? String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces) : ""
        guard constantTimeEqual(given, token) else { return (401, "Unauthorized: send the token from FlightDeck Settings as 'Authorization: Bearer <token>'") }
        // GET opens a session's notification stream and DELETE ends a session (legacy revisions; MCPHTTPStream.swift).
        guard ["POST", "GET", "DELETE"].contains(method) else { return (405, "Method not allowed: POST JSON-RPC messages to /mcp") }
        return nil
    }

    /// A fresh random token: 32 bytes from the system CSPRNG, as URL-safe base64 (43 characters).
    public static func newToken() -> String {
        var g = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &g) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// An HTTP/1.1 server for the MCP endpoint on 127.0.0.1. One request per connection (answered with
/// `Connection: close`), at most 8 connections at once, 10 s to send the request, 1 MB per request body and per
/// response. Handling a request may take longer than the read timeout (sample_stacks, checkup); the timeout only
/// guards reading. State is touched only on the server's serial queue.
public final class MCPHTTPServer: @unchecked Sendable {
    public static let maxBody = 1 << 20, maxHeader = 16 << 10, maxResponse = 1 << 20

    let queue = DispatchQueue(label: "flightdeck.mcp.http", qos: .userInitiated)
    private var listener: NWListener?
    private var connections = 0
    /// Open SSE streams (touched only on `queue`), limited to `maxStreams`.
    var streams = 0
    public static let maxStreams = 4
    let server: MCPServer
    private let token: String
    public let requestedPort: UInt16
    /// The bound port while running.
    public private(set) var port: UInt16?

    /// `port` 0 picks a free port (tests); read `port` once `start` has reported ready.
    public init(port: UInt16, token: String, server: MCPServer) { requestedPort = port; self.token = token; self.server = server }

    /// Starts listening; `ready` is called once with nil on success or an error message (e.g. the port is in use).
    public func start(ready: @escaping @Sendable (String?) -> Void = { _ in }) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let l: NWListener
        do { l = try NWListener(using: params) } catch { ready("\(error)"); return }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        var reported = false   // only touched on `queue`
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready:
                self?.port = l.port?.rawValue
                if !reported { reported = true; ready(nil) }
            case .failed(let e), .waiting(let e):
                if !reported { reported = true; ready("\(e)") }
                l.cancel()
            default: break
            }
        }
        l.start(queue: queue)
    }

    public func stop() { queue.async { [self] in listener?.cancel(); listener = nil; port = nil } }

    private func accept(_ c: NWConnection) {
        guard connections < 8 + Self.maxStreams else { c.cancel(); return }
        connections += 1
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .cancelled, .failed: self?.queue.async { self?.connections -= 1 }
            default: break
            }
        }
        c.start(queue: queue)
        let state = RequestState()
        queue.asyncAfter(deadline: .now() + 10) { if !state.received && c.state != .cancelled { c.cancel() } }
        receive(c, state)
    }

    /// Per-connection progress, touched only on `queue`.
    private final class RequestState { var buf = Data(); var received = false }

    private func receive(_ c: NWConnection, _ st: RequestState) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { st.buf.append(data) }
            switch Self.parse(st.buf) {
            case .incomplete where !done && err == nil: self.receive(c, st)
            case .incomplete: c.cancel()
            case .bad(let status, let msg): st.received = true; self.send(c, status: status, body: Self.errorJSON(msg))
            case .request(let method, let path, let headers, let body):
                st.received = true
                self.respond(c, method: method, path: path, headers: headers, body: body)
            }
        }
    }

    enum Parsed { case incomplete, bad(Int, String), request(String, String, [String: String], Data) }

    /// Parses an HTTP/1.1 request from what has arrived so far: headers (names lowercased), then a body of
    /// Content-Length bytes or chunked transfer encoding. Size limits are enforced as data arrives.
    static func parse(_ buf: Data) -> Parsed {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > maxHeader ? .bad(431, "Request headers too large") : .incomplete
        }
        let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let line = head[0].split(separator: " ")
        guard line.count >= 2 else { return .bad(400, "Malformed request line") }
        var headers: [String: String] = [:]
        for h in head.dropFirst() {
            guard let colon = h.firstIndex(of: ":") else { continue }
            headers[h[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = h[h.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = buf[end.upperBound...]
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch dechunk(Data(rest)) {
            case .incomplete: return .incomplete
            case .malformed: return .bad(400, "Malformed chunked body")
            case .tooLarge: return .bad(413, "Request body too large (limit 1 MB)")
            case .body(let body): return .request(String(line[0]), String(line[1]), headers, body)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .bad(400, "Bad Content-Length") }
        guard length <= maxBody else { return .bad(413, "Request body too large (limit 1 MB)") }
        guard rest.count >= length else { return .incomplete }
        return .request(String(line[0]), String(line[1]), headers, Data(rest.prefix(length)))
    }

    enum Dechunked: Equatable { case incomplete, malformed, tooLarge, body(Data) }

    /// Decodes a chunked transfer-encoded body. Trailers after the last chunk are ignored.
    static func dechunk(_ d: Data) -> Dechunked {
        var out = Data(), i = d.startIndex
        while true {
            // A size line longer than 32 bytes without its CRLF is garbage, not a slow client.
            guard let lineEnd = d[i...].range(of: Data("\r\n".utf8)) else { return d.endIndex - i > 32 ? .malformed : .incomplete }
            let sizeText = String(decoding: d[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { return .malformed }
            if size == 0 { return .body(out) }
            if out.count + size > maxBody { return .tooLarge }
            let start = lineEnd.upperBound
            guard d.endIndex - start >= size + 2 else { return .incomplete }
            out.append(d[start..<(start + size)])
            i = start + size + 2
        }
    }

    private func respond(_ c: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        if let (status, msg) = MCPHTTPGate.check(method: method, path: path, headers: headers, token: token) {
            var extra: [(String, String)] = []
            if status == 401 { extra.append(("WWW-Authenticate", "Bearer realm=\"FlightDeck\"")) }
            if status == 405 { extra.append(("Allow", "POST")) }
            return send(c, status: status, body: Self.errorJSON(msg), extra: extra)
        }
        if method != "POST" || Self.isListen(body) { return respondStreaming(c, method: method, headers: headers, body: body) }
        let server = self.server
        Task {
            let reply = await server.handle(body, headers: headers)
            self.queue.async {
                guard var data = reply.body?.data else { return self.send(c, status: reply.status, body: nil) }
                if data.count > Self.maxResponse { data = Self.errorJSON("Response too large") }
                self.send(c, status: reply.status, body: data, extra: reply.sessionID.map { [("Mcp-Session-Id", $0)] } ?? [])
            }
        }
    }

    /// A JSON-RPC error with no id, for refusals that happen before the message is read.
    static func errorJSON(_ msg: String) -> Data {
        (["jsonrpc": "2.0", "error": ["code": .int(MCPServer.Code.invalidRequest), "message": .str(msg)]] as JSON).data
    }

    static let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                          405: "Method Not Allowed", 406: "Not Acceptable", 429: "Too Many Requests", 413: "Payload Too Large", 431: "Request Header Fields Too Large", 503: "Service Unavailable"]

    func send(_ c: NWConnection, status: Int, body: Data?, extra: [(String, String)] = []) {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Error")\r\n"
        if let body { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" } else { head += "Content-Length: 0\r\n" }
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var d = Data(head.utf8)
        if let body { d.append(body) }
        c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
    }
}
