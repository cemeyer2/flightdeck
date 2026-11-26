// Certificate pinning (fingerprint format and the trust-on-first-use policy) and the Keychain wrapper, which uses a
// test-only service name and deletes everything it created.
import XCTest
import Security
@testable import FlightDeckCore

final class UniFiSecurityTests: XCTestCase {
    /// A self-signed EC certificate for CN=unifi.test, generated with openssl for this test. Its fingerprint, from
    /// `openssl x509 -noout -fingerprint -sha256`:
    static let certDER = Data(base64Encoded: "MIIBXjCCAQSgAwIBAgIUfj8Qp5CNSI6GRK55gnDpdQqqb4IwCgYIKoZIzj0EAwIwFTETMBEGA1UEAwwKdW5pZmkudGVzdDAeFw0yNjExMTgwNTAzMjJaFw0zNjExMTUwNTAzMjJaMBUxEzARBgNVBAMMCnVuaWZpLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQ7m9/3xbYJCp3esvFvAjPicpAsU7ufR2nij5JskgrcwsF+cBTVIqTid+kDS5iz3Xux9QBQ3AxTpYcvMM4mgzMfozIwMDAdBgNVHQ4EFgQUPh6DhbPUujX+mpGIIWVtT07OpyMwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEA+DRXg9AaYp2o7Xo/CTBuA/fsRLtcK/WK0Tk3B576DzkCIBifaEJVnmhEOX5x1VQbaCQDV+nRuOLwz+LTiUQPVGpH")!
    static let certFP = "31:C9:64:8D:32:B7:88:09:4E:BF:20:EB:12:CD:4E:35:D3:27:9E:2C:DE:E3:E9:F8:EE:B8:93:33:66:89:5B:18"

    func testFingerprintMatchesOpenSSL() throws {
        XCTAssertEqual(CertificatePin.fingerprint(der: Self.certDER), Self.certFP)
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, Self.certDER as CFData))
        XCTAssertEqual(CertificatePin.fingerprint(cert), Self.certFP)
    }

    func testFingerprintComparisonIgnoresFormatting() {
        let pasted = Self.certFP.lowercased().replacingOccurrences(of: ":", with: " ")
        XCTAssertEqual(CertificatePin.decide(presented: Self.certFP, systemTrusted: false, pinned: pasted), .accept)
    }

    func testTrustOnFirstUsePolicy() {
        let fp = Self.certFP, other = String(repeating: "AB:", count: 31) + "AB"
        // No pin: a self-signed certificate must be confirmed by the user; a publicly trusted one is fine.
        XCTAssertEqual(CertificatePin.decide(presented: fp, systemTrusted: false, pinned: nil), .askUser(fingerprint: fp))
        XCTAssertEqual(CertificatePin.decide(presented: fp, systemTrusted: true, pinned: nil), .accept)
        XCTAssertEqual(CertificatePin.decide(presented: fp, systemTrusted: false, pinned: ""), .askUser(fingerprint: fp))
        // Pinned: only that certificate, even when the system would trust a different one.
        XCTAssertEqual(CertificatePin.decide(presented: fp, systemTrusted: false, pinned: fp), .accept)
        XCTAssertEqual(CertificatePin.decide(presented: other, systemTrusted: false, pinned: fp), .changed(pinned: fp, presented: other))
        XCTAssertEqual(CertificatePin.decide(presented: other, systemTrusted: true, pinned: fp), .changed(pinned: fp, presented: other))
    }

    func testChangedCertificateErrorNamesBothFingerprints() {
        let e = UniFiError.certificateChanged(pinned: "AA:BB", presented: "CC:DD")
        XCTAssertTrue(e.localizedDescription.contains("AA:BB") && e.localizedDescription.contains("CC:DD"))
    }

    func testPresentedFingerprintIsOfferedForUntrustedAndChangedCertificates() {
        XCTAssertEqual(UniFiError.untrustedCertificate(fingerprint: "AA:BB").presentedFingerprint, "AA:BB")
        XCTAssertEqual(UniFiError.certificateChanged(pinned: "AA:BB", presented: "CC:DD").presentedFingerprint, "CC:DD")
        XCTAssertNil(UniFiError.unauthorized("x").presentedFingerprint)
    }

    func testHostnameStripsPort() {
        XCTAssertEqual(UniFiConfig(host: "unifi.local:8443").hostname, "unifi.local")
        XCTAssertEqual(UniFiConfig(host: " 192.168.1.1 ").hostname, "192.168.1.1")
        XCTAssertEqual(UniFiConfig(host: "[fd00::1]:443").hostname, "fd00::1")
        XCTAssertEqual(UniFiConfig(host: "fd00::1").hostname, "fd00::1")
    }

    func testKeychainRoundTrip() throws {
        let kc = Keychain(service: "com.flightdeck.tests.unifi.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        do { try kc.set("first", account: "apiKey") } catch {
            // CI runners without an unlocked login keychain can't store items; that isn't a bug in the wrapper.
            throw XCTSkip("Keychain not available here: \(error)")
        }
        XCTAssertEqual(kc.get("apiKey"), "first")
        try kc.set("second ✓", account: "apiKey")
        XCTAssertEqual(kc.get("apiKey"), "second ✓", "set replaces the existing item")
        try kc.set("pw", account: "password")
        XCTAssertNil(kc.get("missing"))
        try kc.delete("apiKey")
        XCTAssertNil(kc.get("apiKey")); XCTAssertEqual(kc.get("password"), "pw")
        XCTAssertNoThrow(try kc.delete("apiKey"), "deleting a missing item is fine")
        try kc.deleteAll()
        XCTAssertNil(kc.get("password"))
    }
}
