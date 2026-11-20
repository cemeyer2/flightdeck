import Foundation
import Network
// Fleet, part 7: the host's socket. An NWListener on the local network, advertised over Bonjour as _flightdeck._tcp
// (when `advertise`), using the MCP server's HTTP/1.1 parser. Like the MCP and metrics servers: one request per
// connection, at most 8 at once, 10 s to send it, nothing running between requests. Connections from anything but a
// private, link-local or loopback address are dropped before a byte is read, so even a Mac with a public address or
// a port forward doesn't serve the internet. Peer-to-peer (AWDL) and cellular interfaces are excluded.

public enum FleetNetwork {
    /// True for addresses that can only be on the local network: 10/8, 172.16/12, 192.168/16, 169.254/16, 127/8,
    /// ::1, fe80::/10, fc00::/7, and IPv4-mapped forms of those.
    public static func isLocal(_ e: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = e else { return false }
        switch host {
        case .ipv4(let a): return isLocalV4(Array(a.rawValue))
        case .ipv6(let a):
            let b = Array(a.rawValue)
            guard b.count == 16 else { return false }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }                       // ::1
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }                                // fe80::/10
            if (b[0] & 0xfe) == 0xfc { return true }                                                // fc00::/7
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isLocalV4(Array(b[12...])) }
            return false
        default: return false
        }
    }

    static func isLocalV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
    }
}

public final class FleetListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "flightdeck.fleet.http", qos: .utility)
    private var listener: NWListener?
    private var connections = 0
    private let server: FleetServer
    public let requestedPort: UInt16
    private let advertise: Bool, serviceName: String?, loopbackOnly: Bool
    /// The bound port while running.
    public private(set) var port: UInt16?

    /// `port` 0 picks a free one (Bonjour tells viewers which). `loopbackOnly` binds 127.0.0.1 (tests, `--fleet-serve`).
    public init(server: FleetServer, port: UInt16 = 0, advertise: Bool, serviceName: String? = nil, loopbackOnly: Bool = false) {
        self.server = server; requestedPort = port; self.advertise = advertise; self.serviceName = serviceName; self.loopbackOnly = loopbackOnly
    }

    public func start(ready: @escaping @Sendable (String?) -> Void = { _ in }) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        params.prohibitedInterfaceTypes = [.cellular]
        let port = NWEndpoint.Port(rawValue: requestedPort) ?? .any
        if loopbackOnly { params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port) }
        let l: NWListener
        do { l = loopbackOnly ? try NWListener(using: params) : try NWListener(using: params, on: port) } catch { ready("\(error)"); return }
        if advertise {
            let txt = NWTXTRecord(["id": server.hostID, "v": String(FleetProtocol.version)])
            l.service = NWListener.Service(name: serviceName, type: FleetProtocol.serviceType, domain: "local.", txtRecord: txt)
        }
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
        guard connections < 8, FleetNetwork.isLocal(c.endpoint) else { c.cancel(); return }
        connections += 1
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .cancelled, .failed: self?.queue.async { self?.connections -= 1 }
            default: break
            }
        }
        c.start(queue: queue)
        let state = State()
        queue.asyncAfter(deadline: .now() + 10) { if !state.received && c.state != .cancelled { c.cancel() } }
        receive(c, state)
    }

    private final class State { var buf = Data(); var received = false }

    private func receive(_ c: NWConnection, _ st: State) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { st.buf.append(data) }
            if st.buf.count > 64 << 10 { st.received = true; return self.send(c, FleetResponse.error(FleetError(413, "Request too large"))) }
            switch MCPHTTPServer.parse(st.buf) {
            case .incomplete where !done && err == nil: self.receive(c, st)
            case .incomplete: c.cancel()
            case .bad(let status, let msg): st.received = true; self.send(c, .error(FleetError(status, msg)))
            case .request(let method, let path, let headers, let body):
                st.received = true
                let server = self.server
                Task {
                    let r = await server.handle(method: method, path: path, headers: headers, body: body)
                    self.queue.async { self.send(c, r) }
                }
            }
        }
    }

    private func send(_ c: NWConnection, _ r: FleetResponse) {
        let reason = MCPHTTPServer.reasons[r.status] ?? "Error"
        var d = Data("HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        d.append(r.body)
        c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
    }
}
