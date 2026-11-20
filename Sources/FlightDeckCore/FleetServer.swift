import Foundation
// Fleet, part 6: the host's request handling, independent of the socket (FleetListener feeds it). Read-only: the only
// state a request can change is pairing (which needs the code shown on this Mac) and the replay cache.
//
//   GET  /v1/hello          anyone on the local network: FleetHello (ID, computer name, whether pairing is open)
//   POST /v1/pair/start     pairing, only while open in Settings (FleetPairing.swift)
//   POST /v1/pair/commit
//   POST /v1/pair/reveal
//   GET  /v1/status         paired viewers only (signed request, sealed reply): FleetStatus

public struct FleetResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    static func json<T: Encodable>(_ v: T, status: Int = 200) -> FleetResponse {
        FleetResponse(status: status, contentType: "application/json", body: (try? JSONEncoder.fleet.encode(v)) ?? Data("{}".utf8))
    }
    static func error(_ e: FleetError) -> FleetResponse { json(["error": e.message], status: e.status) }
}

public final class FleetServer: @unchecked Sendable {
    public let store: FleetStore
    private let lock = NSLock()
    private let pairing: FleetPairingHost
    private var replay = FleetReplayCache()
    private let status: @Sendable () async -> FleetStatus?
    /// Called (on the server's queue) when a viewer finishes pairing, after it has been saved.
    public var onPaired: (@Sendable (FleetPeer) -> Void)?

    public var hostID: String { pairing.hostID }

    /// `status` builds the reply for a paired viewer (on demand; nothing is computed between requests).
    public init(store: FleetStore, hostName: String, status: @escaping @Sendable () async -> FleetStatus?) {
        self.store = store
        pairing = FleetPairingHost(hostID: store.instanceID, hostName: hostName)
        self.status = status
    }

    // MARK: Pairing window (Settings)

    public struct PairingState: Equatable, Sendable {
        public var code: String?, openUntil: Date?, lockedFor: TimeInterval?
        public init(code: String? = nil, openUntil: Date? = nil, lockedFor: TimeInterval? = nil) { self.code = code; self.openUntil = openUntil; self.lockedFor = lockedFor }
    }
    public func pairingState(now: Date = Date()) -> PairingState {
        lock.lock(); defer { lock.unlock() }
        let open = pairing.isOpen(now: now)
        return PairingState(code: open ? pairing.code : nil, openUntil: open ? pairing.openUntil : nil, lockedFor: pairing.lockedFor(now: now))
    }
    @discardableResult public func openPairing(now: Date = Date()) -> String { lock.lock(); defer { lock.unlock() }; return pairing.open(now: now) }
    public func closePairing() { lock.lock(); pairing.close(); lock.unlock() }

    // MARK: Requests

    /// `headers` have lowercased names.
    public func handle(method: String, path: String, headers: [String: String], body: Data, now: Date = Date()) async -> FleetResponse {
        let p = path.split(separator: "?").first.map(String.init) ?? path
        switch (method, p) {
        case ("GET", "/v1/hello"):
            let open = lock.withLock { pairing.isOpen(now: now) && pairing.lockedFor(now: now) == nil }
            return .json(FleetHello(id: pairing.hostID, name: pairing.hostName, pairingOpen: open))
        case ("POST", "/v1/pair/start"):
            return pair(body) { (r: FleetPairing.Start) in self.pairing.start(r, now: now) }
        case ("POST", "/v1/pair/commit"):
            return pair(body) { (r: FleetPairing.Commit) in self.pairing.commit(r, now: now) }
        case ("POST", "/v1/pair/reveal"):
            var paired: FleetPeer?
            let reply = pair(body) { (r: FleetPairing.Reveal) -> Result<FleetPairing.Revealed, FleetError> in
                self.pairing.reveal(r, now: now).map { paired = $0.1; return $0.0 }
            }
            if let paired { store.addViewer(paired); onPaired?(paired) }
            return reply
        case ("GET", "/v1/status"):
            switch authenticate(method: method, path: p, headers: headers, now: now) {
            case .failure(let e): return .error(e)
            case .success(let (viewer, nonce)):
                guard let s = await status() else { return .error(FleetError(503, "FlightDeck on that Mac has no data yet")) }
                store.update { st in
                    // Note when each viewer last read this Mac (at most once an hour, so the file isn't rewritten per poll).
                    if let i = st.viewers.firstIndex(where: { $0.id == viewer.id }), now.timeIntervalSince(st.viewers[i].lastSeen ?? .distantPast) > 3600 {
                        st.viewers[i].lastSeen = now
                    }
                }
                guard let json = try? JSONEncoder.fleet.encode(s),
                      let sealed = try? FleetCrypto.sealResponse(json, secret: viewer.secretData, requestNonce: nonce, hostID: hostID) else {
                    return .error(FleetError(500, "Couldn't encode the status"))
                }
                return FleetResponse(status: 200, contentType: "application/octet-stream", body: sealed)
            }
        case (_, "/v1/hello"), (_, "/v1/status"), (_, "/v1/pair/start"), (_, "/v1/pair/commit"), (_, "/v1/pair/reveal"):
            return .error(FleetError(405, "Method not allowed"))
        default:
            return .error(FleetError(404, "Not found"))
        }
    }

    private func pair<In: Decodable, Out: Encodable>(_ body: Data, _ step: (In) -> Result<Out, FleetError>) -> FleetResponse {
        guard body.count <= 4096, let r = try? JSONDecoder.fleet.decode(In.self, from: body) else { return .error(FleetError(400, "Malformed pairing request")) }
        lock.lock(); let out = step(r); lock.unlock()
        switch out { case .success(let v): return .json(v); case .failure(let e): return .error(e) }
    }

    /// Checks a signed request: known viewer, fresh timestamp, unused nonce, valid MAC. Returns the viewer and nonce.
    public func authenticate(method: String, path: String, headers: [String: String], now: Date) -> Result<(FleetPeer, String), FleetError> {
        let unauthorized = FleetError(401, "Not paired with this Mac (or it was removed there). Pair again.")
        guard let client = headers["x-fleet-client"], let timeText = headers["x-fleet-time"], let time = Int(timeText),
              let nonce = headers["x-fleet-nonce"], let mac = headers["x-fleet-mac"],
              let nonceData = Data(base64Encoded: nonce), nonceData.count == 16 else { return .failure(unauthorized) }
        guard let viewer = store.viewer(client) else { return .failure(unauthorized) }
        guard abs(now.timeIntervalSince1970 - Double(time)) <= FleetCrypto.clockWindow else {
            return .failure(FleetError(401, "The two Macs' clocks differ by more than 5 minutes. Turn on Set time automatically on both."))
        }
        guard FleetCrypto.verifyMAC(mac, secret: viewer.secretData, method: method, path: path, time: time, nonce: nonce, clientID: client, hostID: hostID) else {
            return .failure(unauthorized)
        }
        // Only after the MAC checks out, so unauthenticated junk can't fill the cache.
        let fresh = lock.withLock { replay.use(client: client, nonce: nonce, now: now) }
        guard fresh else { return .failure(FleetError(401, "Replayed request")) }
        return .success((viewer, nonce))
    }
}
