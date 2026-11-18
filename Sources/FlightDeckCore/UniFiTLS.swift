// Trust on first use for UniFi consoles, which almost always present a self-signed certificate (or one issued for a
// hostname other than the IP the user typed). TLS validation is never turned off: a URLSession delegate scoped to the one
// configured host accepts the server only if the system trusts its certificate, or if the SHA-256 fingerprint of its leaf
// certificate equals the one the user approved. Once a fingerprint is pinned, only that certificate is accepted, even if
// the system would trust another one; a changed certificate is refused with an error naming both fingerprints.
import Foundation
import Security
import CryptoKit

public enum CertificatePin {
    /// SHA-256 over the certificate's DER encoding, as uppercase hex pairs ("AB:CD:…"), the format browsers and
    /// `openssl x509 -fingerprint -sha256` show, so the user can compare it with the console's own display.
    public static func fingerprint(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    public static func fingerprint(_ cert: SecCertificate) -> String { fingerprint(der: SecCertificateCopyData(cert) as Data) }

    /// Fingerprints compare without regard to case, separators or whitespace (users may paste them in any format).
    public static func normalize(_ fp: String) -> String { fp.uppercased().filter(\.isHexDigit) }

    public enum Decision: Equatable, Sendable {
        case accept
        /// No pin yet and the system doesn't trust the certificate: ask the user whether to trust this fingerprint.
        case askUser(fingerprint: String)
        /// A pin exists and the server presented a different certificate: refuse.
        case changed(pinned: String, presented: String)
    }

    /// The pinning policy, separate from Security framework plumbing so it can be unit-tested.
    public static func decide(presented: String, systemTrusted: Bool, pinned: String?) -> Decision {
        if let pinned, !pinned.isEmpty {
            return normalize(pinned) == normalize(presented) ? .accept : .changed(pinned: pinned, presented: presented)
        }
        return systemTrusted ? .accept : .askUser(fingerprint: presented)
    }
}

/// URLSession delegate that applies `CertificatePin.decide` to server-trust challenges from `host` only. Challenges
/// from any other host (there shouldn't be any: the session only talks to the console) get default handling, so
/// nothing else is ever trusted by this delegate. The last decision is kept so the client can turn a cancelled
/// connection into a clear error.
public final class PinningDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    public let host: String
    private let pinned: String?
    private let lock = NSLock()
    private var _last: CertificatePin.Decision?
    public var lastDecision: CertificatePin.Decision? { lock.lock(); defer { lock.unlock() }; return _last }

    public init(host: String, pinnedFingerprint: String?) { self.host = host; self.pinned = pinnedFingerprint }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host.lowercased() == host.lowercased(), let trust = space.serverTrust else {
            completion(.performDefaultHandling, nil); return
        }
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completion(.cancelAuthenticationChallenge, nil); return
        }
        let systemTrusted = SecTrustEvaluateWithError(trust, nil)
        let d = CertificatePin.decide(presented: CertificatePin.fingerprint(leaf), systemTrusted: systemTrusted, pinned: pinned)
        lock.lock(); _last = d; lock.unlock()
        if d == .accept { completion(.useCredential, URLCredential(trust: trust)) } else { completion(.cancelAuthenticationChallenge, nil) }
    }
}
