import Foundation
import Network
// Web dashboard, part 2b: who may connect. Decided per remote address before a byte is read, from the address, the
// interface the connection arrived on and the allowlist. Tailnet is tested before local because Tailscale's IPv6
// range sits inside fc00::/7. A connection is local only when it arrived on Wi-Fi or Ethernet: private-range peers
// over a VPN or Tailscale are not "the local network". Tailnet entries are honoured only for connections arriving
// on the Tailscale interface, and not-local entries only with Advanced on. Everything fails closed.

public enum WebAddressClass: Sendable { case loopback, local, tailnet, notLocal }

public enum WebAdmission: Equatable, Sendable {
    case drop, admit
    /// Loopback not listed in the allowlist: served only if the Host header is loopback too (see WebHTTP.gate), so a
    /// reverse proxy passing an outside Host through is refused.
    case admitIfLoopbackHost
}

public enum WebAccess {
    /// Ranges that can only be on the local network (FleetNetwork.isLocal's list) as prefixes, so a whole entry can
    /// be classified.
    static let localRanges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8",
                              "::1/128", "fe80::/10", "fc00::/7"].map { WebPrefix($0)! }

    static func isTailnet(_ p: WebPrefix) -> Bool { WebPrefix.tailnetV4.contains(p) || WebPrefix.tailnetV6.contains(p) }

    /// nil when the arrival interface is unknown (the caller drops the connection).
    public static func classify(remote: WebIP, arrival: WebInterface?, context: WebNetworkContext) -> WebAddressClass? {
        if remote.isLoopback { return .loopback }
        guard let arrival else { return nil }
        if arrival.kind == .tailscale && WebPrefix.isTailnet(remote) { return .tailnet }
        if arrival.kind == .lan {
            let privateRange = localRanges.contains { $0.contains(remote) } && !WebPrefix.isTailnet(remote)
            if privateRange || context.lanPrefixes.contains(where: { $0.contains(remote) }) { return .local }
        }
        return .notLocal
    }

    public static func admit(remote: WebIP, arrivalAddress: WebIP?, context: WebNetworkContext, allowlist: WebAllowlist) -> WebAdmission {
        let arrival = arrivalAddress.flatMap(context.interface(owning:))
        guard let cls = classify(remote: remote, arrival: arrival, context: context) else { return .drop }
        switch cls {
        case .loopback: return allowlist.contains(remote) ? .admit : .admitIfLoopbackHost
        case _ where allowlist.entries.isEmpty: return cls == .local ? .admit : .drop
        // A tailnet entry is honoured only for tailnet arrivals: a CGNAT or other-VPN 100.64/10 peer reaching Wi-Fi
        // (or a 100.64/10 on-link LAN address) never matches one.
        case .local: return nonTailnetEntryContains(remote, allowlist) ? .admit : .drop
        // Only a tailnet entry admits a tailnet address: a broad ULA entry (fd00::/8) is meant for LAN devices.
        case .tailnet: return allowlist.entries.contains { isTailnet($0.prefix) && $0.prefix.contains(remote) } ? .admit : .drop
        case .notLocal: return context.advanced && nonTailnetEntryContains(remote, allowlist) ? .admit : .drop
        }
    }

    static func nonTailnetEntryContains(_ remote: WebIP, _ allowlist: WebAllowlist) -> Bool {
        allowlist.entries.contains { !isTailnet($0.prefix) && $0.prefix.contains(remote) }
    }

    /// How Settings labels an entry. The two "ignored" labels mean the entry currently matches nothing; `localOnly` is
    /// a broader entry (0.0.0.0/0) that, with Advanced off, admits only its local part.
    public enum EntryLabel: Equatable, Sendable {
        case local, localOnly, tailnet, tailnetIgnored, notLocal, notLocalIgnored
        public var text: String {
            switch self {
            case .local: return "local network"
            case .localOnly: return "Allows local devices only (turn on Advanced to allow the rest)"
            case .tailnet: return "tailnet"
            case .tailnetIgnored: return "Tailscale not detected — ignored"
            case .notLocal: return "outside the local network"
            case .notLocalIgnored: return "Not a local address — ignored (turn on Advanced to allow)"
            }
        }
        public var isIgnored: Bool { self == .tailnetIgnored || self == .notLocalIgnored }
    }

    public static func label(_ p: WebPrefix, context: WebNetworkContext) -> EntryLabel {
        if isTailnet(p) { return context.tailscaleInterfaceUp ? .tailnet : .tailnetIgnored }
        let local = localRanges + context.lanPrefixes
        if local.contains(where: { $0.contains(p) }) { return .local }
        if context.advanced { return .notLocal }
        // Prefixes overlap only by nesting, so an entry reaching into a local range contains it.
        return local.contains(where: { p.contains($0) }) ? .localOnly : .notLocalIgnored
    }
}

/// A one-click allowlist addition offered in Settings.
public struct WebSuggestion: Hashable, Sendable {
    public var label: String
    /// Normalized entries it adds.
    public var entries: [String]
    public var warning: String?
    public init(label: String, entries: [String], warning: String? = nil) { self.label = label; self.entries = entries; self.warning = warning }
}

public enum WebSuggestions {
    public static let tailnetWarning = "Every device on your tailnet, including machines shared with you, will be able to see this dashboard."
    public static let firstAddNote = "Only listed addresses can connect now — add your local subnet too if you still want it"

    /// This Mac's Wi-Fi and Ethernet subnets ("Wi-Fi: 192.168.1.0/24", plus the IPv6 on-link prefix). Link-local
    /// ranges are left out: they are local already and mean nothing to type.
    public static func local(_ ctx: WebNetworkContext) -> [WebSuggestion] {
        let linkLocal = [WebPrefix("169.254.0.0/16")!, WebPrefix("fe80::/10")!]
        var seen = Set<WebPrefix>(), out: [WebSuggestion] = []
        for i in ctx.interfaces where i.kind == .lan {
            for a in i.addresses {
                let p = a.prefix
                guard !p.isHost, !linkLocal.contains(where: { $0.contains(p) }), seen.insert(p).inserted else { continue }
                out.append(WebSuggestion(label: "\(i.displayName): \(p)", entries: [p.description]))
            }
        }
        return out
    }

    /// "Allow my tailnet", only while Tailscale is detected.
    public static func tailnet(_ ctx: WebNetworkContext) -> WebSuggestion? {
        guard ctx.tailscaleDetected else { return nil }
        return WebSuggestion(label: "Allow my tailnet", entries: [WebPrefix.tailnetV4.description, WebPrefix.tailnetV6.description],
                             warning: tailnetWarning)
    }

    /// Hides suggestions whose entries are all listed already.
    public static func visible(_ s: [WebSuggestion], current: WebAllowlist) -> [WebSuggestion] {
        let have = Set(current.entries.map(\.prefix))
        return s.filter { !$0.entries.compactMap(WebPrefix.init).allSatisfy(have.contains) }
    }

    /// Appends the suggestion's entries on new lines. Adding to an empty list changes its meaning from "any local
    /// address" to "only these", so that case returns a note.
    public static func adding(_ s: WebSuggestion, to raw: String) -> (text: String, note: String?) {
        let current = WebAllowlist.parse(raw)
        let have = Set(current.entries.map(\.prefix))
        let add = s.entries.filter { WebPrefix($0).map { !have.contains($0) } ?? false }
        let base = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        let text = ([base].filter { !$0.isEmpty } + add).joined(separator: "\n")
        return (text, current.isEmpty ? firstAddNote : nil)
    }
}

public enum WebTailscale {
    static let bundleIDs: Set = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos", "io.tailscale.ipn.macos.network-extension"]
    /// The Tailscale daemon or one of its apps is running (the weaker of the two detection signals).
    public static func processRunning(processNames: [String], bundleIDs: [String]) -> Bool {
        processNames.contains("tailscaled") || bundleIDs.contains(where: Self.bundleIDs.contains)
    }
}
