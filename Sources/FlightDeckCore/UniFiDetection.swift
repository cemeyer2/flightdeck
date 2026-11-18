// Suggesting a UniFi console without being asked to connect anywhere. Two signals, both about the default gateway:
//  1. its MAC (from the ARP table) has a Ubiquiti OUI, which costs nothing on the network;
//  2. `https://<gateway>/` answers like UniFi OS (the page title, the `UNIFI_OS_MANIFEST` script, or `/api/system`
//     returning UniFi OS fields). This is an unauthenticated GET with a short timeout, made only while the UniFi view is
//     open, and it never sends credentials. The certificate isn't checked for this probe because nothing is sent
//     and nothing is trusted: the result only pre-fills the host field, and the real connection still asks the user to
//     trust the certificate.
import Foundation

public enum UniFiDetection {
    /// Ubiquiti Inc. OUIs from the IEEE registry (MA-L assignments seen on UniFi gear).
    public static let ubiquitiOUIs: Set<String> = [
        "00:15:6d", "00:27:22", "04:18:d6", "18:e8:29", "1c:6a:1b", "24:5a:4c", "24:a4:3c", "28:70:4e", "44:d9:e7",
        "60:22:32", "68:72:51", "68:d7:9a", "70:a7:41", "74:83:c2", "74:ac:b9", "78:45:58", "78:8a:20", "80:2a:a8",
        "84:78:48", "94:2a:6f", "9c:05:d6", "ac:8b:a9", "b4:fb:e4", "d0:21:f9", "d8:b3:70", "dc:9f:db", "e0:63:da",
        "e4:38:83", "f0:9f:c2", "f4:92:bf", "f4:e2:c6", "fc:ec:da",
    ]

    public static func isUbiquiti(mac: String) -> Bool {
        let m = UniFi.normalizeMAC(mac)
        return m.count == 17 && ubiquitiOUIs.contains(String(m.prefix(8)))
    }

    /// MAC for `ip` from `arp -an` output ("? (192.168.1.1) at 74:ac:b9:5e:21:b3 on en0 ifscope [ethernet]").
    /// Incomplete entries ("(incomplete)") yield nil.
    public static func mac(forIP ip: String, arpOutput: String) -> String? {
        for line in arpOutput.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard let i = parts.firstIndex(of: "at"), i > 0, i + 1 < parts.count, parts[i - 1] == "(\(ip))" else { continue }
            let m = String(parts[i + 1])
            return m.contains(":") ? UniFi.normalizeMAC(m) : nil
        }
        return nil
    }

    /// True if a page or `/api/system` body looks like UniFi OS.
    public static func looksLikeUniFiOS(_ body: String) -> Bool {
        body.contains("UNIFI_OS_MANIFEST") || body.contains("<title>UniFi OS</title>") || body.contains("<title>UniFi Network</title>")
            || (body.contains("\"hardware\"") && body.contains("\"shortname\"")) || body.contains("unifi-network-app")
    }

    public struct Suggestion: Sendable, Equatable {
        public var host: String
        /// Why it was suggested, for the UI ("Gateway 192.168.1.1 is Ubiquiti hardware (74:ac:b9:…)").
        public var reason: String
    }

    /// Checks the default gateway (blocking: runs `route` and `arp`, then at most one short HTTPS GET). Call off the
    /// main thread. `probeHTTP: false` limits it to the ARP check.
    public static func suggest(probeHTTP: Bool = true, timeout: TimeInterval = 3) async -> Suggestion? {
        guard let gw = NetworkConfig.defaultRoute()?.gateway, !gw.contains(":") else { return nil }   // IPv4 gateways only
        if let arp = Shell.run("/usr/sbin/arp", ["-an"], timeout: 3), let mac = mac(forIP: gw, arpOutput: arp), isUbiquiti(mac: mac) {
            return Suggestion(host: gw, reason: "The default gateway \(gw) is Ubiquiti hardware (MAC \(mac)).")
        }
        guard probeHTTP, let url = URL(string: "https://\(gw)/") else { return nil }
        let probe = SignatureProbe(host: gw)
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout; c.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: c, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        let body = String(decoding: data.prefix(64_000), as: UTF8.self)
        return looksLikeUniFiOS(body) ? Suggestion(host: gw, reason: "The default gateway \(gw) answers like a UniFi OS console.") : nil
    }

    /// Accepts the gateway's certificate for the signature probe only (a GET that carries no credentials and whose
    /// answer is only used to suggest a host name). Scoped to that one host; anything else gets default handling.
    final class SignatureProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
        let host: String
        init(host: String) { self.host = host }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let s = challenge.protectionSpace
            if s.authenticationMethod == NSURLAuthenticationMethodServerTrust, s.host == host, let t = s.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: t))
            } else { completionHandler(.performDefaultHandling, nil) }
        }
    }
}
