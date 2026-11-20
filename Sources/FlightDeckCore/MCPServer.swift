import Foundation
// The Model Context Protocol layer: JSON-RPC 2.0 parsing, version handling and method dispatch, independent of the
// transport. The app's HTTP endpoint (MCPHTTPServer) and `FlightDeck --mcp` over stdio (MCPStdio) both hand each
// incoming message to `MCPServer.handle` and send back what it returns.
//
// MCP has two eras (https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning):
//   • legacy (2024-11-05 … 2025-11-25): the client opens with `initialize`, which negotiates a version for the rest of
//     the session;
//   • modern (2026-07-28 and later): no handshake; every request carries its version and client capabilities in
//     `params._meta["io.modelcontextprotocol/…"]`, and results carry `resultType`.
// This server is "dual-era": it answers `initialize` for legacy clients and serves modern requests statelessly. It
// keeps no per-session state at all (every tool is argument-driven; the one that writes, `mark`, keeps its marks in a file), so a legacy client that skips
// `initialize`, or a stdio proxy that switches between the app and standalone mode mid-session, still works.
// The one exception is notifications (MCPServerEvents.swift): a legacy `resources/subscribe` lives on an MCPSession
// (stdio's, or an HTTP session from `initialize`), and a modern `subscriptions/listen` lives as long as its request.

/// One tool as listed by `tools/list`.
public struct MCPToolSpec: Sendable {
    public var name: String
    public var title: String
    public var description: String
    /// JSON Schema (2020-12) of the `arguments` object.
    public var inputSchema: JSON
    /// False only for `mark`, which writes FlightDeck's own marks file (never anything else on the Mac). Clients use
    /// the annotations to decide whether to ask before calling.
    public var readOnly: Bool
    public init(name: String, title: String, description: String, inputSchema: JSON, readOnly: Bool = true) {
        self.name = name; self.title = title; self.description = description; self.inputSchema = inputSchema; self.readOnly = readOnly
    }
}

/// What a tool call produced: text for the model, and whether it is an error the model should read and correct
/// (a bad PID, an out-of-range argument), as opposed to a protocol error.
public struct MCPToolResult: Sendable {
    public var text: String
    public var isError: Bool
    public init(text: String, isError: Bool = false) { self.text = text; self.isError = isError }
    public static func error(_ message: String) -> MCPToolResult { MCPToolResult(text: message, isError: true) }
}

/// The tools a server exposes. `MCPTools` is the real implementation; tests may supply others.
public protocol MCPToolProvider: Sendable {
    var specs: [MCPToolSpec] { get }
    func call(_ name: String, arguments: JSON) async -> MCPToolResult
}

/// A reply to one incoming message. `body` is nil for notifications (HTTP 202, nothing written on stdio).
public struct MCPReply: Sendable {
    public var status: Int
    public var body: JSON?
    /// Set on an HTTP `initialize` reply: the `Mcp-Session-Id` to send back (resource subscriptions need it).
    public var sessionID: String? = nil
}

public final class MCPServer: Sendable {
    /// Newest first. The modern revision is served statelessly; the rest via `initialize`.
    public static let modernVersions = ["2026-07-28"]
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static var supportedVersions: [String] { modernVersions + legacyVersions }

    /// JSON-RPC error codes: the standard ones, and the MCP-defined ones from the 2026-07-28 schema.
    public enum Code {
        public static let parseError = -32700, invalidRequest = -32600, methodNotFound = -32601, invalidParams = -32602, internalError = -32603
        public static let headerMismatch = -32020, unsupportedVersion = -32022
    }
    /// Tool text is cut at this many bytes (about 12k tokens), so one call can never flood a model's context. Each
    /// tool also limits itself (counts, windows); this is the backstop.
    public static let maxToolTextBytes = 48_000

    static let metaVersionKey = "io.modelcontextprotocol/protocolVersion"
    static let metaServerInfoKey = "io.modelcontextprotocol/serverInfo"

    let name: String, version: String, instructions: String
    let tools: MCPToolProvider
    /// Resources and the event hub behind subscriptions (MCPServerEvents.swift); nil when the tools have none.
    let resources: MCPResourceProvider?
    /// HTTP sessions (created by `initialize`), for resource subscriptions only.
    let sessions = MCPSessionTable()

    public init(name: String = "flightdeck", version: String, instructions: String, tools: MCPToolProvider) {
        self.name = name; self.version = version; self.instructions = instructions; self.tools = tools
        resources = tools as? MCPResourceProvider
    }

    var serverInfo: JSON { ["name": .str(name), "title": "FlightDeck", "version": .str(version)] }

    /// Handles one message. `headers` (lowercased names) are passed by the HTTP transport so the request-metadata
    /// headers can be checked against the body; stdio passes nil. `session` is the transport's client state (stdio has
    /// one; over HTTP it is found from `Mcp-Session-Id`). `notify` is where a `subscriptions/listen` stream writes
    /// (stdout, or the HTTP response's SSE stream); that request only returns when its task is cancelled.
    public func handle(_ data: Data, headers: [String: String]? = nil, session: MCPSession? = nil,
                       notify: (@Sendable (JSON) -> Void)? = nil) async -> MCPReply {
        guard let msg = try? JSON.parse(data) else { return error(nil, Code.parseError, "Parse error: the body is not valid JSON", status: 400) }
        // JSON-RPC batches were allowed only in 2025-03-26 and removed after it; no current client sends them.
        guard msg.isObject else { return error(nil, Code.invalidRequest, "Invalid request: expected one JSON-RPC object (batches are not supported)", status: 400) }
        let id = msg["id"]
        // A client's response to a server request: this server never sends requests, so there is nothing to match.
        if msg["method"] == nil && (msg["result"] != nil || msg["error"] != nil) { return MCPReply(status: 202, body: nil) }
        guard msg["jsonrpc"]?.string == "2.0", let method = msg["method"]?.string else {
            return error(id, Code.invalidRequest, "Invalid request: needs \"jsonrpc\": \"2.0\" and a string \"method\"", status: 400)
        }
        // Without an id it's a notification (initialized, cancelled, …): accepted and never answered.
        guard let id else { return MCPReply(status: 202, body: nil) }
        guard id.string != nil || id.int != nil else { return error(nil, Code.invalidRequest, "Invalid request: id must be a string or an integer", status: 400) }
        let params = msg["params"] ?? .object([])
        guard params.isObject else { return error(id, Code.invalidParams, "Invalid params: params must be an object", status: 400) }

        // Modern requests name their version in _meta; anything else is treated as legacy (after or without initialize).
        let requested = params["_meta"]?[Self.metaVersionKey]?.string
        let modern = requested.map { !Self.legacyVersions.contains($0) } ?? false
        if let requested, !Self.supportedVersions.contains(requested) {
            return MCPReply(status: 400, body: errorBody(id, Code.unsupportedVersion, "Unsupported protocol version",
                                                         data: ["supported": .strings(Self.supportedVersions), "requested": .str(requested)]))
        }
        if let headers, let mismatch = headerMismatch(headers, method: method, params: params, bodyVersion: requested) {
            return error(id, Code.headerMismatch, "Header mismatch: \(mismatch)", status: 400)
        }

        var session = session
        if session == nil, let sid = headers?["mcp-session-id"] {
            guard let s = sessions.find(sid) else { return error(id, Code.invalidRequest, "Session not found: send initialize again", status: 404) }
            session = s
        }
        switch method {
        case "initialize":
            // Echo the client's version when it's a legacy one we speak; otherwise offer the newest legacy version
            // (the client then decides whether it can continue).
            let asked = params["protocolVersion"]?.string ?? ""
            let v = Self.legacyVersions.contains(asked) ? asked : Self.legacyVersions[0]
            var reply = ok(id, ["protocolVersion": .str(v), "capabilities": capabilities(session), "serverInfo": serverInfo,
                               "instructions": .str(instructions)], modern: false)
            // Over HTTP a session is only worth having for subscriptions.
            if headers != nil, session == nil, resources?.events != nil { reply.sessionID = sessions.create().id }
            return reply
        case "server/discover":
            return ok(id, ["supportedVersions": .strings(Self.supportedVersions), "capabilities": capabilities(session),
                           "instructions": .str(instructions)], modern: true)
        case "ping":
            return ok(id, [:], modern: modern)
        case "tools/list":
            let list: [JSON] = tools.specs.map { t in
                ["name": .str(t.name), "title": .str(t.title), "description": .str(t.description), "inputSchema": t.inputSchema,
                 // Every FlightDeck tool but `mark` only reads; clients use these hints to skip confirmation prompts. `mark`
                 // adds to FlightDeck's own marks file: not read-only, but not destructive, and each call adds a new mark.
                 "annotations": ["title": .str(t.title), "readOnlyHint": .bool(t.readOnly), "destructiveHint": false,
                                 "idempotentHint": .bool(t.readOnly), "openWorldHint": false]]
            }
            return ok(id, ["tools": .array(list)], modern: modern)
        case "tools/call":
            guard let name = params["name"]?.string else { return error(id, Code.invalidParams, "Invalid params: tools/call needs a tool name", status: 200) }
            guard tools.specs.contains(where: { $0.name == name }) else {
                return error(id, Code.invalidParams, "Unknown tool: \(name). Available: \(tools.specs.map(\.name).joined(separator: ", "))", status: 200)
            }
            let args = params["arguments"] ?? .object([])
            guard args.isObject else { return error(id, Code.invalidParams, "Invalid params: arguments must be an object", status: 200) }
            let r = await tools.call(name, arguments: args)
            return ok(id, ["content": [["type": "text", "text": .str(Self.capped(r.text))]], "isError": r.isError ? true : nil], modern: modern)
        case "prompts/list":
            let list: [JSON] = MCPPrompts.all.map { p in
                ["name": .str(p.name), "title": .str(p.title), "description": .str(p.description),
                 "arguments": .array(p.arguments.map { ["name": .str($0.name), "description": .str($0.description), "required": .bool($0.required)] })]
            }
            return ok(id, ["prompts": .array(list)], modern: modern)
        case "prompts/get":
            guard let name = params["name"]?.string, let p = MCPPrompts.find(name) else {
                return error(id, Code.invalidParams, "Unknown prompt. Available: \(MCPPrompts.all.map(\.name).joined(separator: ", "))", status: 200)
            }
            // Arguments arrive as strings (the spec's prompt arguments are string-valued); blanks count as missing.
            var args: [String: String] = [:]
            if case .object(let o)? = params["arguments"] {
                for (k, v) in o { if let s = v.string ?? v.int.map(String.init), !s.trimmingCharacters(in: .whitespaces).isEmpty { args[k] = s } }
            }
            if let missing = p.arguments.first(where: { $0.required && args[$0.name] == nil }) {
                return error(id, Code.invalidParams, "Missing required argument '\(missing.name)' for prompt \(name)", status: 200)
            }
            return ok(id, ["description": .str(p.description),
                           "messages": [["role": "user", "content": ["type": "text", "text": .str(p.render(args))]]]], modern: modern)
        default:
            if let r = await handleEvents(method, id: id, params: params, modern: modern, session: session, notify: notify) { return r }
            // A modern server answers an unknown method with HTTP 404 so clients can tell it from a legacy server.
            return error(id, Code.methodNotFound, "Method not found: \(method)", status: modern ? 404 : 200)
        }
    }

    /// Tools and prompts (fixed lists, so nothing ever list-changes); resources with subscriptions when the tools
    /// have an event hub; the Claude Code channel capability in channel mode.
    func capabilities(_ session: MCPSession?) -> JSON {
        var c: [(String, JSON)] = [("tools", ["listChanged": false]), ("prompts", ["listChanged": false])]
        if let r = resources { c.append(("resources", ["subscribe": .bool(r.events != nil), "listChanged": false])) }
        if session?.channel == true { c.append(("experimental", ["claude/channel": .object([])])) }
        return .object(c)
    }

    /// Ends an HTTP session (DELETE with its `Mcp-Session-Id`); false if there was none.
    public func endSession(_ id: String) -> Bool { sessions.remove(id) }
    /// The HTTP session with this id, for the GET stream.
    public func session(_ id: String) -> MCPSession? { sessions.find(id) }

    /// Cuts text at `maxToolTextBytes` (on a character boundary) and says so, so the model knows to narrow its request.
    static func capped(_ s: String) -> String {
        guard s.utf8.count > maxToolTextBytes else { return s }
        var cut = s.utf8.prefix(maxToolTextBytes)
        while String(cut) == nil { cut = cut.dropLast() }   // don't split a multi-byte character
        return String(cut)! + "\n…[truncated at \(maxToolTextBytes / 1000) KB: ask for fewer items or a shorter window]"
    }

    /// The Streamable HTTP binding mirrors body fields into headers (MCP-Protocol-Version, Mcp-Method, Mcp-Name).
    /// A header that is present must agree with the body; a missing one is tolerated, since legacy clients don't
    /// send them. Returns a description of the first disagreement.
    func headerMismatch(_ h: [String: String], method: String, params: JSON, bodyVersion: String?) -> String? {
        if let hv = h["mcp-protocol-version"], let bodyVersion, hv != bodyVersion {
            return "MCP-Protocol-Version header '\(hv)' does not match body version '\(bodyVersion)'"
        }
        if let hm = h["mcp-method"], hm != method { return "Mcp-Method header '\(hm)' does not match body method '\(method)'" }
        if let hn = h["mcp-name"], let bn = params["name"]?.string ?? params["uri"]?.string, Self.decodeHeader(hn) != bn {
            return "Mcp-Name header does not match body value '\(bn)'"
        }
        return nil
    }

    /// Decodes the `=?base64?…?=` sentinel form used for header values that aren't plain ASCII.
    static func decodeHeader(_ v: String) -> String {
        guard v.hasPrefix("=?base64?"), v.hasSuffix("?="), v.count >= 11 else { return v }
        let b64 = String(v.dropFirst(9).dropLast(2))
        return Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) } ?? v
    }

    // MARK: Replies

    /// A result. Modern results carry `resultType` and identify the server in `_meta`, as the 2026-07-28 revision asks;
    /// legacy results are left exactly as those revisions define them.
    func ok(_ id: JSON, _ result: JSON, modern: Bool) -> MCPReply {
        var r: [(String, JSON)] = []
        if modern { r.append(("resultType", "complete")) }
        if case .object(let o) = result { r += o }
        if modern { r.append(("_meta", .object([(Self.metaServerInfoKey, serverInfo)]))) }
        return MCPReply(status: 200, body: ["jsonrpc": "2.0", "id": id, "result": .object(r)])
    }

    func errorBody(_ id: JSON?, _ code: Int, _ message: String, data: JSON? = nil) -> JSON {
        ["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": .int(code), "message": .str(message), "data": data]]
    }

    func error(_ id: JSON?, _ code: Int, _ message: String, status: Int) -> MCPReply {
        MCPReply(status: status, body: errorBody(id, code, message))
    }
}
