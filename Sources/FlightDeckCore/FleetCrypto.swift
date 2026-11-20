import Foundation
import CryptoKit
// Fleet, part 3: the cryptography, all from CryptoKit. See FleetPairing.swift for the pairing protocol and README
// (Fleet) for the summary.
//
// After pairing, each viewer/host pair shares one 32-byte secret. Two keys are derived from it with HKDF-SHA256:
//   • the request key: every request carries `X-Fleet-Client` (the viewer's ID), `X-Fleet-Time` (Unix seconds),
//     `X-Fleet-Nonce` (16 random bytes) and `X-Fleet-MAC` = HMAC-SHA256 over method, path, time, nonce and both IDs.
//     The host accepts a time within ±5 minutes of its clock and each nonce once (replays are refused);
//   • the response key: the reply body is sealed with ChaCha20-Poly1305, with the request's nonce as associated data,
//     so it is private, can't be altered, and can't be replayed as the answer to a different request.

public enum FleetCrypto {
    public static let label = "FD-FLEET-1"
    /// How far a request's timestamp may be from the host's clock.
    public static let clockWindow: TimeInterval = 300

    public static func random(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    /// A pairing code: 6 decimal digits, uniformly from the system CSPRNG.
    public static func newCode() -> String {
        var g = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0..<1_000_000, using: &g))
    }

    /// The digits of a code as typed: spaces and dashes are ignored; nil unless exactly 6 digits remain.
    public static func digits(_ code: String) -> [Int]? {
        let d = code.filter { !$0.isWhitespace && $0 != "-" }
        guard d.count == FleetPairing.rounds, d.allSatisfy(\.isASCII), d.allSatisfy(\.isNumber) else { return nil }
        return d.compactMap { $0.wholeNumberValue }
    }

    /// The per-digit commitment / proof of the pairing protocol: HMAC-SHA256 keyed by a fresh 16-byte nonce over the
    /// role, both public keys (own first), the round and the digit. Hiding (the nonce is secret until revealed) and
    /// binding (HMAC is collision resistant).
    public static func commitment(nonce: Data, role: String, own: Data, other: Data, round: Int, digit: Int) -> Data {
        var m = Data("\(label)|commit|\(role)|\(round)|\(digit)|".utf8)
        m.append(own); m.append(other)
        return Data(HMAC<SHA256>.authenticationCode(for: m, using: SymmetricKey(data: nonce)))
    }

    /// The pairing secret: X25519 between the two ephemeral keys, through HKDF salted with the hash of the whole
    /// transcript (both public keys and every revealed nonce), bound to both IDs.
    public static func pairingSecret(shared: SharedSecret, transcript: Data, viewerID: String, hostID: String) -> Data {
        let salt = Data(SHA256.hash(data: transcript))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("\(label)|pair|\(viewerID)|\(hostID)".utf8),
                                                 outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    static func derive(_ secret: Data, _ purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), info: Data("\(label)|\(purpose)".utf8), outputByteCount: 32)
    }

    /// The MAC a request carries, as base64.
    public static func requestMAC(secret: Data, method: String, path: String, time: Int, nonce: String, clientID: String, hostID: String) -> String {
        let m = Data("\(label)\n\(method)\n\(path)\n\(time)\n\(nonce)\n\(clientID)\n\(hostID)".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: m, using: derive(secret, "request"))).base64EncodedString()
    }

    public static func verifyMAC(_ given: String, secret: Data, method: String, path: String, time: Int, nonce: String, clientID: String, hostID: String) -> Bool {
        guard let g = Data(base64Encoded: given) else { return false }
        let m = Data("\(label)\n\(method)\n\(path)\n\(time)\n\(nonce)\n\(clientID)\n\(hostID)".utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(g, authenticating: m, using: derive(secret, "request"))   // constant time
    }

    static func responseAAD(nonce: String, hostID: String) -> Data { Data("\(label)|response|\(nonce)|\(hostID)".utf8) }

    public static func sealResponse(_ body: Data, secret: Data, requestNonce: String, hostID: String) throws -> Data {
        try ChaChaPoly.seal(body, using: derive(secret, "response"), authenticating: responseAAD(nonce: requestNonce, hostID: hostID)).combined
    }

    public static func openResponse(_ sealed: Data, secret: Data, requestNonce: String, hostID: String) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: derive(secret, "response"),
                            authenticating: responseAAD(nonce: requestNonce, hostID: hostID))
    }

    /// The four request headers for `method path`, signed with `secret`.
    public static func signedHeaders(secret: Data, method: String, path: String, clientID: String, hostID: String, now: Date = Date())
        -> (headers: [(String, String)], nonce: String) {
        let time = Int(now.timeIntervalSince1970)
        let nonce = random(16).base64EncodedString()
        let mac = requestMAC(secret: secret, method: method, path: path, time: time, nonce: nonce, clientID: clientID, hostID: hostID)
        return ([("X-Fleet-Client", clientID), ("X-Fleet-Time", String(time)), ("X-Fleet-Nonce", nonce), ("X-Fleet-MAC", mac)], nonce)
    }
}

/// Remembers each (client, nonce) seen within the clock window, so a captured request can't be sent again.
public struct FleetReplayCache: Sendable {
    private var seen: [String: Date] = [:]
    public static let capacity = 4096
    public init() {}

    /// False if this nonce was already used (or the cache is full of fresh entries: refuse rather than forget).
    public mutating func use(client: String, nonce: String, now: Date) -> Bool {
        let key = client + "|" + nonce
        if seen.count >= Self.capacity / 2 { seen = seen.filter { now.timeIntervalSince($0.value) <= FleetCrypto.clockWindow * 2 } }
        guard seen[key] == nil, seen.count < Self.capacity else { return false }
        seen[key] = now
        return true
    }
}
