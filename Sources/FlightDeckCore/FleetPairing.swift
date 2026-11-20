import Foundation
import CryptoKit
// Fleet, part 4: pairing. The sharing Mac (the host) shows a 6-digit code; the viewer's user types it in once. A
// 6-digit code is only ~20 bits, so it must never be usable for an offline guess, and the key must not come from it.
// The protocol is Bluetooth's Passkey Entry, one decimal digit per round:
//
//   1. start:  viewer → host: viewer ID, name, ephemeral X25519 public key PKv.   host → viewer: its key PKs.
//   2. six rounds, i = 1…6, with dᵢ the i-th digit of the code:
//        commit: viewer → host: Cvᵢ = HMAC(Nvᵢ, "V"‖PKv‖PKs‖i‖dᵢ)          (Nvᵢ: 16 fresh random bytes, kept secret)
//                host → viewer: Nsᵢ and Psᵢ = HMAC(Nsᵢ, "S"‖PKs‖PKv‖i‖dᵢ)   (the viewer checks Psᵢ against its dᵢ)
//        reveal: viewer → host: Nvᵢ                                          (the host checks Cvᵢ against its dᵢ)
//   3. both derive the secret: HKDF(X25519(PKv, PKs), salt = SHA-256 of PKv‖PKs‖all nonces), bound to both IDs.
//
// A passive listener sees only public keys and nonces: the X25519 secret stays unknown. An active attacker must, in
// every round, commit to a digit before learning it: impersonating the viewer it commits blind (the host's proof then
// reveals that digit, but a wrong commitment fails the session and the host switches to a new code); impersonating the
// host it must prove a digit before the viewer reveals anything. So a man in the middle succeeds with probability
// 10⁻⁶ per attempt, and the host allows 5 failed attempts per 10 minutes, only while its user has pairing open.

public enum FleetPairing {
    public static let rounds = 6

    public struct Start: Codable, Sendable { public var viewerID: String; public var viewerName: String; public var publicKey: String }
    public struct Started: Codable, Sendable { public var session: String; public var publicKey: String; public var hostID: String; public var hostName: String }
    public struct Commit: Codable, Sendable { public var session: String; public var round: Int; public var commitment: String }
    public struct Proof: Codable, Sendable { public var nonce: String; public var proof: String }
    public struct Reveal: Codable, Sendable { public var session: String; public var round: Int; public var nonce: String }
    public struct Revealed: Codable, Sendable { public var done: Bool }
}

/// A refusal: the HTTP status and a message for the viewer's user.
public struct FleetError: Error, Sendable, Equatable, CustomStringConvertible {
    public var status: Int
    public var message: String
    public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    public var description: String { message }
}

/// A Mac this one has paired with: on the host, a viewer allowed to read it; on the viewer, a host it reads.
public struct FleetPeer: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// The 32-byte pairing secret, base64. Never shown, logged or sent.
    public var secret: String
    public var pairedAt: Date
    /// Viewer side: the Bonjour instance name last seen for this host, and the last time it answered.
    public var serviceName: String? = nil
    public var lastSeen: Date? = nil
    public var model: String? = nil
    public var kind: String? = nil
    public init(id: String, name: String, secret: Data, pairedAt: Date) {
        self.id = id; self.name = name; self.secret = secret.base64EncodedString(); self.pairedAt = pairedAt
    }
    public var secretData: Data { Data(base64Encoded: secret) ?? Data() }
}

/// The host's side of pairing. Not thread-safe: FleetServer calls it under its lock.
public final class FleetPairingHost {
    public static let windowLength: TimeInterval = 300, sessionTimeout: TimeInterval = 60
    public static let maxFailures = 5, failureWindow: TimeInterval = 600

    public let hostID: String, hostName: String
    /// The code shown in Settings while pairing is open; nil when closed.
    public private(set) var code: String?
    public private(set) var openUntil: Date?
    private var failures: [Date] = []
    private var session: Session?

    private final class Session {
        let id = FleetCrypto.random(16).base64EncodedString()
        let viewerID: String, viewerName: String, pkV: Data
        let key = Curve25519.KeyAgreement.PrivateKey()
        let started: Date
        var round = 1
        var pendingCommitment: Data?
        var transcript: Data
        init(viewerID: String, viewerName: String, pkV: Data, started: Date) {
            self.viewerID = viewerID; self.viewerName = viewerName; self.pkV = pkV; self.started = started
            transcript = pkV + key.publicKey.rawRepresentation
        }
    }

    public init(hostID: String, hostName: String) { self.hostID = hostID; self.hostName = hostName }

    public func isOpen(now: Date) -> Bool { code != nil && (openUntil ?? .distantPast) > now }
    /// Seconds until pairing reopens after too many failures, or nil.
    public func lockedFor(now: Date) -> TimeInterval? {
        let recent = failures.filter { now.timeIntervalSince($0) < Self.failureWindow }
        guard recent.count >= Self.maxFailures, let first = recent.first else { return nil }
        return Self.failureWindow - now.timeIntervalSince(first)
    }

    /// Opens a pairing window with a fresh code (the user pressed "Pair a Mac…").
    @discardableResult public func open(now: Date) -> String {
        let c = FleetCrypto.newCode()
        code = c; openUntil = now.addingTimeInterval(Self.windowLength); session = nil
        return c
    }
    public func close() { code = nil; openUntil = nil; session = nil }

    /// A failed attempt: counted, and the code is replaced so nothing learned about it is any use.
    private func fail(_ now: Date, _ message: String) -> FleetError {
        failures.append(now); failures.removeAll { now.timeIntervalSince($0) >= Self.failureWindow }
        session = nil
        if code != nil { code = FleetCrypto.newCode() }
        return FleetError(403, message)
    }

    /// Ends a timed-out session. One that was sent any proof but never finished counts as a failed attempt (and so
    /// changes the code): otherwise an attacker could learn a digit per abandoned session without ever failing.
    private func expire(_ now: Date) {
        guard let s = session, now.timeIntervalSince(s.started) >= Self.sessionTimeout else { return }
        if s.round > 1 || s.pendingCommitment != nil { _ = fail(now, "expired") } else { session = nil }
    }

    private func gate(_ now: Date) -> FleetError? {
        if let s = lockedFor(now: now) { return FleetError(429, "Too many failed pairing attempts. Try again in \(Int(s / 60) + 1) min.") }
        guard isOpen(now: now) else { return FleetError(403, "Pairing isn't open on that Mac. In its FlightDeck Settings › Fleet, click Pair a Mac.") }
        return nil
    }

    public func start(_ r: FleetPairing.Start, now: Date) -> Result<FleetPairing.Started, FleetError> {
        if let e = gate(now) { return .failure(e) }
        if let s = session, now.timeIntervalSince(s.started) < Self.sessionTimeout { return .failure(FleetError(409, "Another Mac is pairing right now. Try again in a minute.")) }
        expire(now)
        if let e = gate(now) { return .failure(e) }
        guard let pk = Data(base64Encoded: r.publicKey), pk.count == 32, (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pk)) != nil,
              !r.viewerID.isEmpty, r.viewerID.count <= 64 else { return .failure(FleetError(400, "Malformed pairing request")) }
        let s = Session(viewerID: r.viewerID, viewerName: String(r.viewerName.prefix(80)), pkV: pk, started: now)
        session = s
        return .success(.init(session: s.id, publicKey: s.key.publicKey.rawRepresentation.base64EncodedString(), hostID: hostID, hostName: hostName))
    }

    private func current(_ id: String, _ round: Int, now: Date) -> Result<Session, FleetError> {
        if let e = gate(now) { return .failure(e) }
        expire(now)
        guard let s = session, s.id == id else {
            return .failure(FleetError(410, "The pairing session expired. Start again."))
        }
        guard s.round == round, (1...FleetPairing.rounds).contains(round) else { return .failure(fail(now, "Pairing messages arrived out of order.")) }
        return .success(s)
    }

    public func commit(_ r: FleetPairing.Commit, now: Date) -> Result<FleetPairing.Proof, FleetError> {
        let s: Session
        switch current(r.session, r.round, now: now) { case .failure(let e): return .failure(e); case .success(let v): s = v }
        guard s.pendingCommitment == nil, let c = Data(base64Encoded: r.commitment), c.count == 32, let digits = code.flatMap(FleetCrypto.digits) else {
            return .failure(fail(now, "Malformed pairing commitment"))
        }
        s.pendingCommitment = c
        let ns = FleetCrypto.random(16)
        let pkS = s.key.publicKey.rawRepresentation
        let proof = FleetCrypto.commitment(nonce: ns, role: "S", own: pkS, other: s.pkV, round: r.round, digit: digits[r.round - 1])
        s.transcript.append(ns)
        return .success(.init(nonce: ns.base64EncodedString(), proof: proof.base64EncodedString()))
    }

    /// The last successful reveal returns the new viewer, which the caller saves; pairing then closes.
    public func reveal(_ r: FleetPairing.Reveal, now: Date) -> Result<(FleetPairing.Revealed, FleetPeer?), FleetError> {
        let s: Session
        switch current(r.session, r.round, now: now) { case .failure(let e): return .failure(e); case .success(let v): s = v }
        guard let c = s.pendingCommitment, let nv = Data(base64Encoded: r.nonce), nv.count == 16, let digits = code.flatMap(FleetCrypto.digits) else {
            return .failure(fail(now, "Malformed pairing reveal"))
        }
        let pkS = s.key.publicKey.rawRepresentation
        let expected = FleetCrypto.commitment(nonce: nv, role: "V", own: s.pkV, other: pkS, round: r.round, digit: digits[r.round - 1])
        guard MCPHTTPGate.constantTimeEqual(expected.base64EncodedString(), c.base64EncodedString()) else {
            return .failure(fail(now, "That code doesn't match. Check the code in the other Mac's FlightDeck Settings › Fleet (it has changed)."))
        }
        // The viewer's nonce goes before the host's nonce of the same round, as the viewer records them.
        s.transcript.insert(contentsOf: nv, at: s.transcript.count - 16)
        s.pendingCommitment = nil
        guard r.round == FleetPairing.rounds else { s.round += 1; return .success((.init(done: false), nil)) }
        guard let pkV = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: s.pkV), let shared = try? s.key.sharedSecretFromKeyAgreement(with: pkV) else {
            return .failure(fail(now, "Pairing key agreement failed"))
        }
        let secret = FleetCrypto.pairingSecret(shared: shared, transcript: s.transcript, viewerID: s.viewerID, hostID: hostID)
        close()
        return .success((.init(done: true), FleetPeer(id: s.viewerID, name: s.viewerName, secret: secret, pairedAt: now)))
    }
}

/// The viewer's side of pairing: pure, so the client and tests drive it the same way.
public final class FleetPairingGuest {
    public let viewerID: String
    let digits: [Int]
    let key = Curve25519.KeyAgreement.PrivateKey()
    private var pkS = Data(), nonces: [Data] = [], transcript = Data()

    public init?(viewerID: String, code: String) {
        guard let d = FleetCrypto.digits(code) else { return nil }
        self.viewerID = viewerID; digits = d
    }
    public var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    public func started(_ r: FleetPairing.Started) -> Bool {
        guard let pk = Data(base64Encoded: r.publicKey), pk.count == 32 else { return false }
        pkS = pk; transcript = key.publicKey.rawRepresentation + pk
        return true
    }

    /// Round `i`'s commitment (base64); its nonce is kept for `reveal`.
    public func commitment(round i: Int) -> String {
        let nv = FleetCrypto.random(16)
        nonces.append(nv)
        return FleetCrypto.commitment(nonce: nv, role: "V", own: key.publicKey.rawRepresentation, other: pkS, round: i, digit: digits[i - 1]).base64EncodedString()
    }

    /// Checks the host's proof for round `i`; on success returns the nonce to reveal.
    public func reveal(round i: Int, proof p: FleetPairing.Proof) -> String? {
        guard let ns = Data(base64Encoded: p.nonce), ns.count == 16, let given = Data(base64Encoded: p.proof), nonces.count == i else { return nil }
        let expected = FleetCrypto.commitment(nonce: ns, role: "S", own: pkS, other: key.publicKey.rawRepresentation, round: i, digit: digits[i - 1])
        guard MCPHTTPGate.constantTimeEqual(expected.base64EncodedString(), given.base64EncodedString()) else { return nil }
        transcript.append(nonces[i - 1]); transcript.append(ns)
        return nonces[i - 1].base64EncodedString()
    }

    public func secret(hostID: String) -> Data? {
        guard let pk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pkS), let shared = try? key.sharedSecretFromKeyAgreement(with: pk) else { return nil }
        return FleetCrypto.pairingSecret(shared: shared, transcript: transcript, viewerID: viewerID, hostID: hostID)
    }
}
