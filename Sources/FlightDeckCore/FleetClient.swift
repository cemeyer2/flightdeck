import Foundation
import Network
// Fleet, part 8: the viewer's side. A tiny HTTP/1.1 client over NWConnection, so a host can be reached by its Bonjour
// service endpoint (resolved by mDNSResponder at connect time) as well as by address in tests. One request per
// connection, 8 s timeout, replies over 2 MB refused.

public struct FleetClient: Sendable {
    public let endpoint: NWEndpoint
    public var timeout: TimeInterval = 8
    public init(endpoint: NWEndpoint) { self.endpoint = endpoint }
    /// A host advertised over Bonjour, by its instance name.
    public init(serviceName: String) { endpoint = .service(name: serviceName, type: FleetProtocol.serviceType, domain: "local.", interface: nil) }
    public init(host: String, port: UInt16) { endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any) }

    public static let maxResponse = 2 << 20

    public func hello() async throws -> FleetHello {
        let (status, body) = try await request("GET", "/v1/hello")
        guard status == 200 else { throw Self.error(status, body) }
        let h = try JSONDecoder.fleet.decode(FleetHello.self, from: body)
        guard h.proto == FleetProtocol.version else { throw FleetError(505, "That Mac runs an incompatible FlightDeck version. Update both.") }
        return h
    }

    /// Runs the whole pairing exchange with `code` and returns the host as a peer to save.
    public func pair(code: String, viewerID: String, viewerName: String, now: Date = Date()) async throws -> FleetPeer {
        guard let g = FleetPairingGuest(viewerID: viewerID, code: code) else { throw FleetError(400, "Enter the 6-digit code shown on the other Mac.") }
        let started: FleetPairing.Started = try await post("/v1/pair/start", FleetPairing.Start(viewerID: viewerID, viewerName: viewerName, publicKey: g.publicKey))
        guard g.started(started) else { throw FleetError(502, "That Mac sent a malformed pairing reply") }
        for i in 1...FleetPairing.rounds {
            let proof: FleetPairing.Proof = try await post("/v1/pair/commit", FleetPairing.Commit(session: started.session, round: i, commitment: g.commitment(round: i)))
            // A wrong proof means the other side doesn't know the code (a typo, or someone in the middle): stop
            // before revealing anything.
            guard let nonce = g.reveal(round: i, proof: proof) else {
                // Tell the host so it ends the session now (rather than blocking pairing for a minute): a random nonce
                // opens to no digit, so the host counts a failed attempt and changes its code. It reveals nothing.
                let abort = FleetPairing.Reveal(session: started.session, round: i, nonce: FleetCrypto.random(16).base64EncodedString())
                _ = try? await post("/v1/pair/reveal", abort) as FleetPairing.Revealed
                throw FleetError(403, "That code doesn't match. Check the code in the other Mac's FlightDeck Settings › Fleet.")
            }
            let r: FleetPairing.Revealed = try await post("/v1/pair/reveal", FleetPairing.Reveal(session: started.session, round: i, nonce: nonce))
            if r.done != (i == FleetPairing.rounds) { throw FleetError(502, "That Mac ended pairing unexpectedly") }
        }
        guard let secret = g.secret(hostID: started.hostID) else { throw FleetError(502, "Pairing key agreement failed") }
        return FleetPeer(id: started.hostID, name: started.hostName, secret: secret, pairedAt: now)
    }

    /// The host's status, signed with the pairing secret; the sealed reply is opened and checked.
    public func status(host: FleetPeer, viewerID: String, now: Date = Date()) async throws -> FleetStatus {
        let path = "/v1/status"
        let signed = FleetCrypto.signedHeaders(secret: host.secretData, method: "GET", path: path, clientID: viewerID, hostID: host.id, now: now)
        let (status, body) = try await request("GET", path, headers: signed.headers)
        guard status == 200 else { throw Self.error(status, body) }
        guard let json = try? FleetCrypto.openResponse(body, secret: host.secretData, requestNonce: signed.nonce, hostID: host.id) else {
            throw FleetError(502, "The reply couldn't be verified (not the paired Mac?)")
        }
        let s = try JSONDecoder.fleet.decode(FleetStatus.self, from: json)
        guard s.identity.id == host.id else { throw FleetError(502, "A different Mac answered") }
        return s
    }

    private func post<In: Encodable, Out: Decodable>(_ path: String, _ body: In) async throws -> Out {
        let (status, data) = try await request("POST", path, body: try JSONEncoder.fleet.encode(body))
        guard status == 200 else { throw Self.error(status, data) }
        return try JSONDecoder.fleet.decode(Out.self, from: data)
    }

    static func error(_ status: Int, _ body: Data) -> FleetError {
        let msg = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
        return FleetError(status, msg ?? "That Mac answered HTTP \(status)")
    }

    /// One HTTP exchange: (status, body).
    public func request(_ method: String, _ path: String, headers: [(String, String)] = [], body: Data = Data()) async throws -> (Int, Data) {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        params.prohibitedInterfaceTypes = [.cellular]
        let c = NWConnection(to: endpoint, using: params)
        var head = "\(method) \(path) HTTP/1.1\r\nHost: flightdeck\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        let out = Data((head + "\r\n").utf8) + body
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Int, Data), Error>) in
            let q = DispatchQueue(label: "flightdeck.fleet.client")
            final class Box: @unchecked Sendable { var done = false; var buf = Data() }   // only touched on `q`
            let box = Box()
            func finish(_ r: Result<(Int, Data), Error>) {
                guard !box.done else { return }
                box.done = true; c.cancel(); cont.resume(with: r)
            }
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isDone, err in
                    if let data { box.buf.append(data) }
                    if box.buf.count > Self.maxResponse { return finish(.failure(FleetError(502, "Reply too large"))) }
                    if let parsed = Self.parseResponse(box.buf, complete: isDone) { return finish(.success(parsed)) }
                    if isDone || err != nil { return finish(.failure(err ?? FleetError(502, "The connection closed early"))) }
                    read()
                }
            }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready: c.send(content: out, completion: .contentProcessed { e in if let e { finish(.failure(e)) } else { read() } })
                case .failed(let e): finish(.failure(e))
                case .waiting(let e): finish(.failure(e))
                default: break
                }
            }
            q.asyncAfter(deadline: .now() + timeout) { finish(.failure(FleetError(504, "No answer (the Mac may be asleep or off)"))) }
            c.start(queue: q)
        }
    }

    /// Status and body once the headers and Content-Length bytes have arrived (or the connection ended).
    static func parseResponse(_ buf: Data, complete: Bool) -> (Int, Data)? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2, let status = Int(first[1]) else { return complete ? (502, Data()) : nil }
        var length: Int?
        for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") { length = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) }
        let body = buf[end.upperBound...]
        if let length { return body.count >= length ? (status, Data(body.prefix(length))) : nil }
        return complete ? (status, Data(body)) : nil
    }
}
