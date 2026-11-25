import Foundation
// The console's networks (VLANs) from the classic `rest/networkconf` list, for the web dashboard's allowlist
// suggestions. Read once when the Settings section is shown; WAN and VPN entries without a subnet are skipped.

public struct UniFiNetwork: Sendable, Equatable, Hashable {
    public var name: String
    /// Normalized ("192.168.1.1/24" → "192.168.1.0/24").
    public var subnet: String
    public var vlan: Int?
    public init(name: String, subnet: String, vlan: Int?) { self.name = name; self.subnet = subnet; self.vlan = vlan }
}

enum UniFiNetworks {
    static func classic(_ data: Data) -> [UniFiNetwork]? {
        // Each field is read leniently, so one row with an unexpected type (vlan as a string) is skipped or
        // degraded rather than failing the whole list.
        struct Row: Decodable {
            var name: String?, ip_subnet: String?, vlan: Int?
            enum CodingKeys: String, CodingKey { case name, ip_subnet, vlan }
            init(from decoder: Decoder) throws {
                guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
                name = try? c.decodeIfPresent(String.self, forKey: .name)
                ip_subnet = try? c.decodeIfPresent(String.self, forKey: .ip_subnet)
                vlan = (try? c.decodeIfPresent(Int.self, forKey: .vlan)) ?? (try? c.decodeIfPresent(String.self, forKey: .vlan)).flatMap { Int($0) }
            }
        }
        struct Envelope: Decodable { var data: [Row] }
        guard let rows = try? JSONDecoder().decode(Envelope.self, from: data).data else { return nil }
        return rows.compactMap { r in
            guard let s = r.ip_subnet, let p = WebPrefix(s) else { return nil }
            return UniFiNetwork(name: r.name ?? "Network", subnet: p.description, vlan: r.vlan)
        }
    }
}

public extension UniFiAPIClient {
    func networks() async throws -> [UniFiNetwork] {
        let data = try await classicGet("/api/s/\(config.site)/rest/networkconf")
        guard let n = UniFiNetworks.classic(data) else { throw UniFiError.notFound("rest/networkconf") }
        return n
    }
}

public extension WebSuggestions {
    /// "UniFi: IoT (VLAN 10): 192.168.10.0/24"; a network outside the local ranges says so, like a typed entry.
    static func unifi(_ n: [UniFiNetwork], context: WebNetworkContext) -> [WebSuggestion] {
        n.compactMap { net in
            guard let p = WebPrefix(net.subnet) else { return nil }
            let label = WebAccess.label(p, context: context)
            let vlan = net.vlan.map { " (VLAN \($0))" } ?? ""
            let suffix = label == .local ? "" : " — " + label.text
            return WebSuggestion(label: "UniFi: \(net.name)\(vlan): \(p)\(suffix)", entries: [p.description])
        }
    }
}
