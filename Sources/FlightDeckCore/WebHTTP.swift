import Foundation
// Web dashboard, part 3: the HTTP pieces the server uses, all pure. A request is only its head (request line and
// headers, at most 8 KB); bodies are refused, never read. Every request passes the same gate in a fixed order: Host
// (anti DNS-rebinding: only this Mac's addresses, localhost and its own .local name), cross-site, method, body,
// path, Accept. A client is identified only by its socket address; no request header can change who it is. No CORS
// header is ever sent, so pages on other sites can't read a reply.

public struct WebRequestHead: Sendable, Equatable {
    public var method: String
    /// Without any query or fragment.
    public var path: String
    /// Lowercased names.
    public var headers: [String: String]
    public init(method: String, path: String, headers: [String: String]) { self.method = method; self.path = path; self.headers = headers }
}

public enum WebHeadParse: Equatable, Sendable {
    case incomplete
    /// Answer with this status and close.
    case bad(Int)
    case head(WebRequestHead)
}

public enum WebRoute: Equatable, Sendable { case page, state, stream, favicon }

public struct WebRefusal: Error, Equatable, Sendable {
    public var status: Int
    public var extra: [(String, String)]
    public init(_ status: Int, extra: [(String, String)] = []) { self.status = status; self.extra = extra }
    public static func == (a: WebRefusal, b: WebRefusal) -> Bool {
        a.status == b.status && a.extra.map { [$0.0, $0.1] } == b.extra.map { [$0.0, $0.1] }
    }
}

public enum WebHTTP {
    public static let maxHeader = 8 << 10
    static let terminator = Data("\r\n\r\n".utf8)

    public static func parseHead(_ buf: Data) -> WebHeadParse {
        guard let end = buf.range(of: terminator) else { return buf.count > maxHeader ? .bad(431) : .incomplete }
        guard end.lowerBound - buf.startIndex <= maxHeader else { return .bad(431) }
        let text = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let request = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard request.count == 3, !request[0].isEmpty, request[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              request[1].hasPrefix("/"), request[2].hasPrefix("HTTP/1.") else { return .bad(400) }
        var headers: [String: String] = [:]
        for l in lines {
            guard let colon = l.firstIndex(of: ":"), colon != l.startIndex else { return .bad(400) }
            let name = l[..<colon].lowercased(), value = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.contains(" ") else { return .bad(400) }
            if let old = headers[name] {
                guard name != "host" else { return .bad(400) }
                headers[name] = old + ", " + value
            } else {
                headers[name] = value
            }
        }
        let path = String(request[1].prefix { $0 != "?" && $0 != "#" })
        return .head(WebRequestHead(method: request[0], path: path, headers: headers))
    }

    /// The host part of a Host value: lowercased, without port or brackets, and without one trailing dot.
    static func hostName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("[") {
            s = String(s.dropFirst().prefix { $0 != "]" })
        } else if s.filter({ $0 == ":" }).count == 1 {
            s = String(s.prefix { $0 != ":" })
        }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func isLoopbackHost(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let h = hostName(raw)
        return h == "localhost" || WebIP(h)?.isLoopback == true
    }

    /// This Mac's interface addresses, loopback, `localhost` and its own `<LocalHostName>.local`. Nothing else: a
    /// name that merely resolves here (DNS rebinding) or a forwarded public address is refused.
    public static func acceptsHost(_ raw: String?, context: WebNetworkContext) -> Bool {
        guard let raw else { return false }
        let h = hostName(raw)
        if h == "localhost" { return true }
        if let ip = WebIP(h) { return ip.isLoopback || context.interfaceAddresses.contains(ip) }
        if let name = context.localHostName?.lowercased(), !name.isEmpty { return h == name + ".local" }
        return false
    }

    public static func gate(_ h: WebRequestHead, admission: WebAdmission, context: WebNetworkContext) -> Result<WebRoute, WebRefusal> {
        let host = h.headers["host"]
        guard acceptsHost(host, context: context), admission != .admitIfLoopbackHost || isLoopbackHost(host) else { return .failure(.init(403)) }
        if h.headers["sec-fetch-site"]?.lowercased() == "cross-site" { return .failure(.init(403)) }
        if let o = h.headers["origin"], MCPHTTPGate.host(of: o) != MCPHTTPGate.host(of: host ?? "") { return .failure(.init(403)) }
        guard h.method == "GET" else { return .failure(.init(405, extra: [("Allow", "GET")])) }
        if let len = h.headers["content-length"], len != "0" { return .failure(.init(400)) }
        if h.headers["transfer-encoding"] != nil { return .failure(.init(400)) }
        let route: WebRoute
        switch h.path {
        case "/": route = .page
        case "/api/state": route = .state
        case "/api/stream": route = .stream
        case "/favicon.svg": route = .favicon
        default: return .failure(.init(404))
        }
        if route == .stream, !(h.headers["accept"] ?? "").lowercased().contains("text/event-stream") { return .failure(.init(406)) }
        return .success(route)
    }

    static let reasons: [Int: String] = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                                         406: "Not Acceptable", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
                                         503: "Service Unavailable"]

    /// Status line and headers. The fixed security headers are always added; the CSP comes from `extra` (the server
    /// passes it on every reply). `contentLength` nil (a stream) sends none.
    public static func responseHead(status: Int, contentType: String?, contentLength: Int?, extra: [(String, String)]) -> Data {
        var lines = ["HTTP/1.1 \(status) \(reasons[status] ?? "Error")"]
        if let contentType { lines.append("Content-Type: \(contentType)") }
        if let contentLength { lines.append("Content-Length: \(contentLength)") }
        lines += extra.map { "\($0.0): \($0.1)" }
        lines += ["X-Content-Type-Options: nosniff", "Referrer-Policy: no-referrer", "Cache-Control: no-store", "Connection: close"]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// One Server-Sent Event. The JSON must be a single line (JSONEncoder output without pretty printing is).
    public static func sseEvent(_ name: String, _ json: Data) -> Data {
        precondition(!json.contains(0x0A) && !json.contains(0x0D), "SSE data must be one line")
        var d = Data("event: \(name)\ndata: ".utf8)
        d.append(json); d.append(contentsOf: [0x0A, 0x0A])
        return d
    }
}

/// Connection and stream counts, overall and per remote address. One slot is kept for loopback, so the user can
/// still open the dashboard on this Mac while other devices fill the rest.
public struct WebConnectionLimits: Sendable {
    public static let total = 8, streams = 6, perAddress = 3, streamsPerAddress = 2
    private var connections: [WebIP: Int] = [:], streamsByAddress: [WebIP: Int] = [:]
    private var connectionCount = 0
    public private(set) var streamCount = 0
    public init() {}

    public mutating func acceptConnection(_ ip: WebIP) -> Bool {
        guard connections[ip, default: 0] < Self.perAddress, connectionCount < (ip.isLoopback ? Self.total : Self.total - 1) else { return false }
        connections[ip, default: 0] += 1; connectionCount += 1
        return true
    }
    public mutating func closeConnection(_ ip: WebIP) {
        guard let n = connections[ip] else { return }
        connections[ip] = n > 1 ? n - 1 : nil; connectionCount -= 1
    }
    public mutating func openStream(_ ip: WebIP) -> Bool {
        guard streamsByAddress[ip, default: 0] < Self.streamsPerAddress, streamCount < Self.streams else { return false }
        streamsByAddress[ip, default: 0] += 1; streamCount += 1
        return true
    }
    public mutating func closeStream(_ ip: WebIP) {
        guard let n = streamsByAddress[ip] else { return }
        streamsByAddress[ip] = n > 1 ? n - 1 : nil; streamCount -= 1
    }
}

/// Logs each refused address at most once per `interval`, remembering at most `capacity` addresses (the one logged
/// longest ago is forgotten first), so a scan can't flood the log or grow memory.
public struct WebRefusalLog: Sendable {
    private var last: [WebIP: Date] = [:]
    let capacity: Int, interval: TimeInterval
    public init(capacity: Int = 256, interval: TimeInterval = 60) { self.capacity = capacity; self.interval = interval }

    public mutating func shouldLog(_ ip: WebIP, now: Date) -> Bool {
        if let t = last[ip], now.timeIntervalSince(t) < interval { return false }
        last[ip] = now
        if last.count > capacity, let oldest = last.min(by: { $0.value < $1.value })?.key { last[oldest] = nil }
        return true
    }
}
