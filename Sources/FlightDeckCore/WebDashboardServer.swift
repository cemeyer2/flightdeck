import Foundation
import Network
// Web dashboard, part 7: the server. An NWListener on every interface (not peer-to-peer or cellular), one serial
// queue for all state. Who may connect is decided once the connection is ready and before a byte is read
// (WebAccess.admit from the socket's remote and local addresses, then the connection limits); refused connections
// are closed without a reply. The head must arrive within `headDeadline`; then WebHTTP.gate decides the route.
// The page, icon and state document are one reply each (`Connection: close`); a stream gets `retry: 3000`, a
// `snapshot` event (with history) and then every published `sample`. A stream that stops reading is closed once
// `maxBacklog` bytes wait unsent. Changing the allowlist or the network re-checks every open connection. Nothing
// runs while no browser is connected except the listener itself.

public final class WebDashboardServer: @unchecked Sendable {
    /// Asks the app for an encoded document (WebDashboardState.encode); nil → 503 (or, for a stream, close). Called
    /// on the server queue.
    public typealias Provider = @Sendable (_ withHistory: Bool, _ reply: @escaping @Sendable (Data?) -> Void) -> Void

    final class Conn {
        let c: NWConnection
        let remote: WebIP
        let arrival: WebIP?
        var admission: WebAdmission
        var host: String?
        var headDone = false
        var stream = false
        /// Joined the fan-out (its snapshot is written).
        var live = false
        /// Bytes handed to `send` whose completion hasn't come back yet.
        var pending = 0
        var closed = false
        init(c: NWConnection, remote: WebIP, arrival: WebIP?, admission: WebAdmission) {
            self.c = c; self.remote = remote; self.arrival = arrival; self.admission = admission
        }
    }

    let queue = DispatchQueue(label: "flightdeck.web.http", qos: .utility)
    private var listener: NWListener?
    private var conns: [ObjectIdentifier: Conn] = [:]
    private var limits = WebConnectionLimits()
    private var refusals = WebRefusalLog()
    private var keepAliveTimer: DispatchSourceTimer?
    private var context: WebNetworkContext
    private var allowlist: WebAllowlist
    private let requestedPort: UInt16, loopbackOnly: Bool
    private let headDeadline: TimeInterval, keepAlive: TimeInterval, maxBacklog: Int, releaseFallback: TimeInterval
    private let provider: Provider
    private let onStreamCount: @Sendable (Int) -> Void
    private let log: @Sendable (String) -> Void
    /// The bound port while running.
    public private(set) var port: UInt16?

    public static let invalidAllowlist = "Fix the allowed addresses first"

    /// `port` 0 picks a free one (tests). `loopbackOnly` binds 127.0.0.1 (tests and the developer demo).
    /// `releaseFallback`: how long after `stop()` the port stops being held for a listener that hasn't cancelled, and
    /// how long a bind that finds the port still taken by such a listener waits for it to cancel.
    public init(port: UInt16, loopbackOnly: Bool = false, context: WebNetworkContext, allowlist: WebAllowlist,
                headDeadline: TimeInterval = 10, keepAlive: TimeInterval = 25, maxBacklog: Int = 256 << 10,
                releaseFallback: TimeInterval = WebDashboardServer.releaseFallback,
                provider: @escaping Provider,
                onStreamCount: @escaping @Sendable (Int) -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        requestedPort = port; self.loopbackOnly = loopbackOnly; self.context = context; self.allowlist = allowlist
        self.headDeadline = headDeadline; self.keepAlive = keepAlive; self.maxBacklog = maxBacklog
        self.releaseFallback = releaseFallback
        self.provider = provider; self.onStreamCount = onStreamCount; self.log = log
    }

    /// What a settings change does to the dashboard, from the port the running server was asked for (nil: none) and
    /// the port wanted (nil: off). Only on/off and a new port start a server; allowlist, Advanced and network changes
    /// are `update(context:allowlist:)` on the running one, so they never rebind.
    public enum Change: Equatable, Sendable {
        /// Stop any running server; nothing to start.
        case off
        /// Keep the running server and hand it the current allowlist and network.
        case update
        /// Stop any running server and start one on the wanted port (it binds once the old listener has let go).
        case start
    }

    public static func change(running: UInt16?, wanted: UInt16?) -> Change {
        guard let wanted else { return .off }
        return running == wanted ? .update : .start
    }

    /// Ports whose listener is still cancelling, process-wide. `stop()` marks its port before it returns and the mark
    /// is cleared when the listener reaches `.cancelled`; a server starting on a marked port binds only then. A mark
    /// the fallback clears first is kept as overdue until that `.cancelled`, so a bind it let fail can try again.
    final class Releasing: @unchecked Sendable {
        typealias Marks = [UInt16: (tokens: Set<Int>, waiting: [@Sendable () -> Void])]
        private let lock = NSLock()
        private var held: Marks = [:]
        private var overdue: Marks = [:]
        private var next = 0

        func begin(_ port: UInt16) -> Int {
            lock.lock(); defer { lock.unlock() }
            next += 1
            held[port, default: ([], [])].tokens.insert(next)
            return next
        }

        /// The listener reached `.cancelled`: clears its mark, held or overdue (again is harmless). The starts waiting
        /// on either kind run once no mark of that kind on the port is left.
        func end(_ port: UInt16, token: Int) {
            lock.lock()
            let run = Self.remove(token, port, &held) + Self.remove(token, port, &overdue)
            lock.unlock()
            for w in run { w() }
        }

        /// The fallback: the mark stops holding up starts on the port and stays overdue until `end`.
        func expire(_ port: UInt16, token: Int) {
            lock.lock()
            guard held[port]?.tokens.contains(token) == true else { lock.unlock(); return }
            overdue[port, default: ([], [])].tokens.insert(token)
            let run = Self.remove(token, port, &held)
            lock.unlock()
            for w in run { w() }
        }

        /// Removes one mark; the starts waiting on the port when it was the last one.
        private static func remove(_ token: Int, _ port: UInt16, _ marks: inout Marks) -> [@Sendable () -> Void] {
            guard var h = marks[port], h.tokens.remove(token) != nil else { return [] }
            if h.tokens.isEmpty { marks[port] = nil; return h.waiting }
            marks[port] = h
            return []
        }

        /// Runs `then` once `port` is free: at once when no listener on it is cancelling.
        func whenFree(_ port: UInt16, _ then: @escaping @Sendable () -> Void) {
            lock.lock()
            if held[port] != nil { held[port]!.waiting.append(then); lock.unlock(); return }
            lock.unlock()
            then()
        }

        /// When a listener on `port` has outlasted its fallback without cancelling: runs `then` once it cancels and
        /// returns true. Otherwise returns false and `then` never runs.
        func whenOverdueEnds(_ port: UInt16, _ then: @escaping @Sendable () -> Void) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard overdue[port] != nil else { return false }
            overdue[port]!.waiting.append(then)
            return true
        }

        func isOverdue(_ port: UInt16) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return overdue[port] != nil
        }
    }
    static let releasing = Releasing()
    /// A cancel that never reports `.cancelled` stops holding up the port after this long (the default). A bind that
    /// then finds the port taken waits up to this long again for that `.cancelled` before it reports the error.
    public static let releaseFallback: TimeInterval = 5

    /// The port this server's listener holds (or is binding), its Releasing mark once stopped, and whether the listener
    /// has already cancelled itself. `attempt` counts binds, so a listener a retry replaced no longer changes it.
    /// Guarded by `lock`: `stop()` may run on any thread, the state handler on `queue`.
    private final class Hold: @unchecked Sendable {
        var port: UInt16?, token: Int?, cancelled = false, stopped = false, attempt = 0
    }
    private let lock = NSLock()
    private let hold = Hold()

    /// Starts listening; `ready` is called once with nil when listening, or an error message. On a fixed port that a
    /// stopped server's listener is still cancelling, it binds once that listener has let go.
    public func start(ready: @escaping @Sendable (String?) -> Void) {
        guard allowlist.invalid.isEmpty else { ready(Self.invalidAllowlist); return }
        guard requestedPort != 0 else { listen(ready: ready); return }
        Self.releasing.whenFree(requestedPort) { [weak self] in
            guard let self else { return }
            self.queue.async { self.listen(ready: ready) }
        }
    }

    /// Binds unless stopped. The stopped check and taking the port are one step, so a `stop()` that lands while this
    /// binds always finds the port to mark. With `retry`, a bind that finds a fixed port still taken by a listener
    /// past its fallback binds once more when that listener reports `.cancelled` (retryWhenOverdueEnds).
    private func listen(retry: Bool = true, ready: @escaping @Sendable (String?) -> Void) {
        lock.lock()
        guard !hold.stopped else { lock.unlock(); return }
        hold.attempt += 1; hold.cancelled = false
        if requestedPort != 0 { hold.port = requestedPort }
        let attempt = hold.attempt
        lock.unlock()
        let wasOverdue = requestedPort != 0 && Self.releasing.isOverdue(requestedPort)
        let params = NWParameters.tcp
        // No address reuse: with it, a bind on every interface succeeds even while another listener holds the port on
        // 127.0.0.1, and Settings would say "Serving" for a port that something else answers on this Mac.
        params.allowLocalEndpointReuse = false
        params.includePeerToPeer = false
        params.prohibitedInterfaceTypes = [.cellular]
        let port = NWEndpoint.Port(rawValue: requestedPort) ?? .any
        if loopbackOnly { params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port) }
        let l: NWListener
        do { l = loopbackOnly ? try NWListener(using: params) : try NWListener(using: params, on: port) } catch {
            // Nothing will report `.cancelled`: let go of the port now, and of a mark a `stop()` meanwhile put on it.
            lock.lock(); hold.cancelled = true; let p = hold.port, t = hold.token; lock.unlock()
            if let p, let t { Self.releasing.end(p, token: t) }
            ready("\(error)"); return
        }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        var reported = false   // only touched on `queue`, where state updates are delivered
        let lock = lock, hold = hold
        l.stateUpdateHandler = { [weak self] st in
            lock.lock(); let current = hold.attempt == attempt; lock.unlock()
            switch st {
            case .ready:
                guard current else { break }
                let bound = l.port?.rawValue
                self?.port = bound
                lock.lock(); hold.port = bound; lock.unlock()
                if !reported { reported = true; ready(nil) }
            // `.waiting` is how a listener reports e.g. "address already in use"; it won't recover on its own here.
            case .failed(let e), .waiting(let e):
                if !reported {
                    reported = true
                    let retrying = retry && current
                        && (self?.retryWhenOverdueEnds(error: "\(e)", wasOverdue: wasOverdue, ready: ready) ?? false)
                    if !retrying { ready("\(e)") }
                }
                l.cancel()
            case .cancelled:
                guard current else { break }
                lock.lock(); hold.cancelled = true; let p = hold.port, t = hold.token; lock.unlock()
                if let p, let t { Self.releasing.end(p, token: t) }
            default: break
            }
        }
        l.start(queue: queue)
    }

    /// On `queue`, after a bind on a fixed port failed: when a stopped listener on it is past its fallback, binds once
    /// more after that listener reports `.cancelled`, or reports `error` after `releaseFallback`, whichever comes
    /// first, and returns true. Neither happens once this server is stopped. `wasOverdue`: such a listener was there
    /// when the bind started; if it has cancelled since, before the failure got here, the bind runs again at once.
    private func retryWhenOverdueEnds(error: String, wasOverdue: Bool,
                                      ready: @escaping @Sendable (String?) -> Void) -> Bool {
        guard requestedPort != 0 else { return false }
        var settled = false   // only touched on `queue`
        let waiting = Self.releasing.whenOverdueEnds(requestedPort) { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard !settled else { return }
                settled = true
                self.listen(retry: false, ready: ready)
            }
        }
        guard waiting else {
            guard wasOverdue else { return false }
            queue.async { [self] in listen(retry: false, ready: ready) }
            return true
        }
        queue.asyncAfter(deadline: .now() + releaseFallback) { [weak self] in
            guard let self, !settled else { return }
            settled = true
            self.lock.lock(); let stopped = self.hold.stopped; self.lock.unlock()
            if !stopped { ready(error) }
        }
        return true
    }

    /// Cancels the listener and every open connection (streams end at once). The port is marked as releasing before
    /// this returns, so a server started on it right after waits for the listener to reach `.cancelled`.
    public func stop() {
        lock.lock()
        hold.stopped = true
        let p = hold.cancelled ? nil : hold.port
        if let p, hold.token == nil { hold.token = Self.releasing.begin(p) }
        let t = hold.token
        lock.unlock()
        if let p, let t {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + releaseFallback) {
                Self.releasing.expire(p, token: t)
            }
        }
        queue.async { [self] in
            listener?.cancel()   // its `.cancelled` clears the mark
            listener = nil; port = nil
            for k in conns.values { k.c.cancel() }
        }
    }

    /// New network facts or allowlist: every open connection is checked again, and those no longer allowed close.
    public func update(context: WebNetworkContext, allowlist: WebAllowlist) {
        queue.async { [self] in
            self.context = context; self.allowlist = allowlist
            for k in conns.values {
                k.admission = allowlist.invalid.isEmpty
                    ? WebAccess.admit(remote: k.remote, arrivalAddress: k.arrival, context: context, allowlist: allowlist) : .drop
                if k.admission == .drop || (k.headDone && !hostAllowed(k)) { k.c.cancel() }
            }
        }
    }

    /// Sends `event: sample` to every stream whose snapshot has been written.
    public func publish(_ document: Data) {
        queue.async { [self] in
            let ev = WebHTTP.sseEvent("sample", document)
            for k in conns.values where k.live { write(k, ev) }
        }
    }

    // MARK: - Connections (all on `queue`)

    private func hostAllowed(_ k: Conn) -> Bool {
        WebHTTP.acceptsHost(k.host, context: context) && (k.admission != .admitIfLoopbackHost || WebHTTP.isLoopbackHost(k.host))
    }

    private func refuse(_ ip: WebIP?, _ reason: String) {
        guard let ip else { log("Web dashboard: refused a connection (\(reason))"); return }
        if refusals.shouldLog(ip, now: Date()) { log("Web dashboard: refused \(ip) (\(reason))") }
    }

    private func accept(_ c: NWConnection) {
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { c.cancel(); return }
            switch st {
            case .ready: self.admitReady(c)
            case .failed, .waiting: c.cancel()
            case .cancelled: self.closed(c)
            default: break
            }
        }
        c.start(queue: queue)
    }

    private static func ip(_ e: NWEndpoint?) -> WebIP? {
        guard case .hostPort(let host, _)? = e else { return nil }
        return WebIP(host)
    }

    /// Runs before anything is read: the socket's own addresses are the only identity a client has.
    private func admitReady(_ c: NWConnection) {
        guard let remote = Self.ip(c.endpoint) else { refuse(nil, "no address"); c.cancel(); return }
        let arrival = Self.ip(c.currentPath?.localEndpoint)
        let admission = allowlist.invalid.isEmpty ? WebAccess.admit(remote: remote, arrivalAddress: arrival, context: context, allowlist: allowlist) : .drop
        guard admission != .drop else { refuse(remote, "not an allowed address"); c.cancel(); return }
        guard limits.acceptConnection(remote) else { refuse(remote, "too many connections"); c.cancel(); return }
        let k = Conn(c: c, remote: remote, arrival: arrival, admission: admission)
        conns[ObjectIdentifier(c)] = k
        queue.asyncAfter(deadline: .now() + headDeadline) { [weak self, weak k] in
            guard let k, !k.headDone, !k.closed else { return }
            self?.refuse(k.remote, "no request within \(Int(self?.headDeadline ?? 0)) s")
            k.c.cancel()
        }
        receiveHead(k, Data())
    }

    private func closed(_ c: NWConnection) {
        guard let k = conns.removeValue(forKey: ObjectIdentifier(c)), !k.closed else { return }
        k.closed = true
        limits.closeConnection(k.remote)
        if k.stream {
            limits.closeStream(k.remote)
            onStreamCount(limits.streamCount)
            if limits.streamCount == 0 { keepAliveTimer?.cancel(); keepAliveTimer = nil }
        }
    }

    private func receiveHead(_ k: Conn, _ soFar: Data) {
        k.c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, err in
            guard let self, !k.closed else { return }
            var buf = soFar; if let data { buf.append(data) }
            switch WebHTTP.parseHead(buf) {
            case .incomplete:
                if done || err != nil { k.c.cancel() } else { self.receiveHead(k, buf) }
            case .bad(let status):
                k.headDone = true
                self.reply(k, status: status)
            case .head(let h):
                k.headDone = true
                k.host = h.headers["host"]
                self.route(k, h)
            }
        }
    }

    /// After the head, a stream keeps reading only to notice the client going away; anything sent is discarded.
    private func drain(_ k: Conn) {
        k.c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, err in
            guard let self, !k.closed else { return }
            if done || err != nil { k.c.cancel() } else { self.drain(k) }
        }
    }

    private func route(_ k: Conn, _ h: WebRequestHead) {
        switch WebHTTP.gate(h, admission: k.admission, context: context) {
        case .failure(let f):
            if f.status == 403 { refuse(k.remote, "Host or Origin not allowed") }
            reply(k, status: f.status, extra: f.extra)
        case .success(.page):
            reply(k, status: 200, type: "text/html; charset=utf-8", body: Data(WebDashboardPage.html.utf8))
        case .success(.favicon):
            reply(k, status: 200, type: "image/svg+xml", body: Data(WebDashboardPage.favicon.utf8))
        case .success(.state):
            provider(false) { [weak self] data in
                self?.queue.async {
                    guard let self, !k.closed else { return }
                    if let data { self.reply(k, status: 200, type: "application/json; charset=utf-8", body: data) }
                    else { self.reply(k, status: 503) }
                }
            }
        case .success(.stream):
            openStream(k)
        }
    }

    private func openStream(_ k: Conn) {
        guard limits.openStream(k.remote) else { reply(k, status: 429, extra: [("Retry-After", "10")]); return }
        k.stream = true
        onStreamCount(limits.streamCount)
        var head = WebHTTP.responseHead(status: 200, contentType: "text/event-stream; charset=utf-8", contentLength: nil,
                                        extra: [("Content-Security-Policy", WebDashboardPage.csp)])
        head.append(Data("retry: 3000\n\n".utf8))
        write(k, head)
        drain(k)
        startKeepAlive()
        provider(true) { [weak self] data in
            self?.queue.async {
                guard let self, !k.closed else { return }
                guard let data else { k.c.cancel(); return }   // the page reconnects
                self.write(k, WebHTTP.sseEvent("snapshot", data))
                k.live = true
            }
        }
    }

    private func startKeepAlive() {
        guard keepAliveTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + keepAlive, repeating: keepAlive)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let ping = Data(": keep-alive\n\n".utf8)
            for k in self.conns.values where k.live { self.write(k, ping) }
        }
        keepAliveTimer = t
        t.resume()
    }

    /// Sends on a stream, or closes it if earlier sends are still waiting beyond `maxBacklog` (a reader that stopped).
    private func write(_ k: Conn, _ data: Data) {
        guard !k.closed else { return }
        guard k.pending <= maxBacklog else { refuse(k.remote, "stopped reading"); k.c.cancel(); return }
        k.pending += data.count
        let n = data.count
        k.c.send(content: data, completion: .contentProcessed { [weak k] err in
            guard let k else { return }
            k.pending -= n
            if err != nil { k.c.cancel() }
        })
    }

    /// A one-shot reply (every reply carries the CSP), then close once it has been sent.
    private func reply(_ k: Conn, status: Int, type: String? = nil, body: Data? = nil, extra: [(String, String)] = []) {
        let b = body ?? Data("\(WebHTTP.reasons[status] ?? "Error")\n".utf8)
        var d = WebHTTP.responseHead(status: status, contentType: type ?? "text/plain; charset=utf-8", contentLength: b.count,
                                     extra: [("Content-Security-Policy", WebDashboardPage.csp)] + extra)
        d.append(b)
        k.c.send(content: d, completion: .contentProcessed { _ in k.c.cancel() })
    }
}
