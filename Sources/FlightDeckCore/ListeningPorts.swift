import Foundation
import Darwin

// The Connections page's "Listening ports" panel: which processes accept connections on which TCP/UDP ports, and
// whether each is reachable from the network (bound to every interface) or only from this Mac (loopback). Loaded on
// demand by the UI, never per sample.
//
// Source: `netstat -anv`, which on current macOS prints a `process:pid` column for every socket, including those of
// root and other users, without needing root (checked on macOS 26/27; launchd:1 and kernel_task:0 appear). If this
// macOS's netstat has no such column, the reader falls back to `lsof`, which only sees the user's own processes, and
// says so via `ListeningScan.coverage`.

/// One listening (TCP LISTEN) or bound-but-unconnected (UDP) socket.
public struct ListeningSocket: Identifiable, Hashable, Sendable {
    /// Where the socket accepts traffic from, judged from its bound address.
    public enum Exposure: String, Sendable, Comparable {
        /// Bound to the wildcard address (`*`, 0.0.0.0, ::): reachable on every interface, so from the network too
        /// (unless the firewall blocks it).
        case allInterfaces = "All interfaces"
        /// Bound to one specific, non-loopback address: reachable on that interface only.
        case oneInterface = "One interface"
        /// 127.0.0.0/8 or ::1: only processes on this Mac can connect.
        case loopback = "This Mac only"
        private var rank: Int { switch self { case .allInterfaces: 0; case .oneInterface: 1; case .loopback: 2 } }
        public static func < (a: Exposure, b: Exposure) -> Bool { a.rank < b.rank }
    }
    public var id: String { "\(pid)|\(proto)\(family)|\(address)|\(port)" }
    public var process: String
    public var pid: Int32
    /// "TCP" or "UDP".
    public var proto: String
    /// "IPv4", "IPv6", "IPv4+6" for a dual-stack socket (netstat's tcp46/udp46), or "IP" when lsof doesn't say.
    public var family: String
    /// The bound address as printed ("*" for the wildcard).
    public var address: String
    public var port: Int
    public var exposure: Exposure

    public init(process: String, pid: Int32, proto: String, family: String, address: String, port: Int) {
        self.process = process; self.pid = pid; self.proto = proto; self.family = family; self.address = address; self.port = port
        exposure = Self.exposure(of: address)
    }

    /// Classifies a bound address. A scoped IPv6 address ("fe80::1%en0") counts as one interface.
    static func exposure(of address: String) -> Exposure {
        let a = address.split(separator: "%").first.map(String.init) ?? address
        if a == "*" || a == "0.0.0.0" || a == "::" || a == "[::]" { return .allInterfaces }
        if a.hasPrefix("127.") || a == "::1" || a == "[::1]" || a == "localhost" { return .loopback }
        return .oneInterface
    }
}

/// The result of one scan, with a plain statement of what it covers.
public struct ListeningScan: Sendable {
    public enum Coverage: Sendable, Equatable {
        /// netstat listed every socket on the system with its owning process.
        case allProcesses
        /// The lsof fallback: only this user's processes are visible without root. The reason says why netstat
        /// wasn't used (no process column, or it printed nothing, as happens inside some sandboxes).
        case ownProcessesOnly(String)
        /// Neither tool produced usable output.
        case failed(String)
    }
    public var sockets: [ListeningSocket]
    public var coverage: Coverage
    /// Read by the root helper (see `scan(helper:)`).
    public var viaHelper: Bool = false
}

public enum ListeningPorts {
    /// Runs netstat for TCP and UDP and, if its output has no process column, lsof instead. Blocking (each tool takes
    /// ~50-500 ms); call off the main thread.
    public static func scan() -> ListeningScan {
        let tcpOut = Shell.run("/usr/sbin/netstat", ["-anv", "-p", "tcp"], timeout: 10)
        let udpOut = Shell.run("/usr/sbin/netstat", ["-anv", "-p", "udp"], timeout: 10)
        if let tcpOut, let udpOut, let t = parseNetstat(tcpOut), let u = parseNetstat(udpOut) {
            return ListeningScan(sockets: sorted(t + u), coverage: .allProcesses)
        }
        let why = (tcpOut ?? "").contains("Proto") ? "this macOS's netstat doesn't show which process owns each socket"
                                                  : "netstat returned no socket table"
        // -iTCP -sTCP:LISTEN restricts TCP to listeners; UDP has no state, so every UDP socket is fetched and the
        // connected ones (with a "->" peer) are dropped by the parser.
        let tcp = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcPn"], timeout: 15)
        let udp = Shell.run("/usr/sbin/lsof", ["-nP", "-iUDP", "-FpcPn"], timeout: 15)
        guard tcp != nil || udp != nil else { return ListeningScan(sockets: [], coverage: .failed("neither netstat nor lsof could be run")) }
        return ListeningScan(sockets: sorted(parseLsof(tcp ?? "") + parseLsof(udp ?? "")), coverage: .ownProcessesOnly(why))
    }

    /// Most exposed first, then by port, so services open to the network head the list.
    static func sorted(_ s: [ListeningSocket]) -> [ListeningSocket] {
        s.sorted { ($0.exposure, $0.port, $0.process, $0.proto) < ($1.exposure, $1.port, $1.process, $1.proto) }
    }

    /// Parses `netstat -anv -p tcp|udp`. Returns nil when the header has no `process:pid` column (older netstat), so
    /// the caller can fall back to lsof rather than show sockets without owners.
    ///
    /// Columns are located from the header rather than hard-coded: the process name can contain spaces (netstat
    /// truncates it, e.g. "Google Chrome He:938"), so the line is split into whitespace tokens and the name is
    /// everything between the fixed numeric columns before it and the fixed columns after it. UDP lines leave the
    /// `(state)` column empty, which is why a state token is only consumed when it isn't a number.
    /// Kept: TCP sockets in LISTEN, and UDP sockets with no peer (foreign address `*.*`), which receive from anyone.
    static func parseNetstat(_ out: String) -> [ListeningSocket]? {
        let lines = out.split(separator: "\n")
        guard let header = lines.first(where: { $0.hasPrefix("Proto") }) else { return nil }
        let h = header.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let stateCol = h.firstIndex(of: "(state)"), let procCol = h.firstIndex(of: "process:pid") else { return nil }
        let numericBefore = procCol - stateCol - 1     // rxbytes txbytes rhiwat shiwat
        let trailing = h.count - procCol - 1           // state options gencnt flags flags1 usecnt rtncnt fltrs
        var out: [ListeningSocket] = []
        var seen = Set<String>()
        for line in lines {
            let t = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard t.count > 5, t[0].hasPrefix("tcp") || t[0].hasPrefix("udp") else { continue }
            let isTCP = t[0].hasPrefix("tcp")
            var i = 5
            var state = ""
            if i < t.count, Int(t[i]) == nil { state = t[i]; i += 1 }
            if isTCP ? state != "LISTEN" : t[4] != "*.*" { continue }
            i += numericBefore
            let end = t.count - trailing
            guard i < end else { continue }
            let owner = t[i..<end].joined(separator: " ")
            guard let colon = owner.lastIndex(of: ":"), let pid = Int32(owner[owner.index(after: colon)...]),
                  let (addr, port) = splitDotted(t[3]) else { continue }
            let s = ListeningSocket(process: String(owner[..<colon]), pid: pid, proto: isTCP ? "TCP" : "UDP",
                                    family: family(t[0]), address: addr, port: port)
            if seen.insert(s.id).inserted { out.append(s) }
        }
        return out
    }

    /// netstat's tcp4/tcp6/tcp46 suffix as an address family label.
    static func family(_ proto: String) -> String {
        if proto.hasSuffix("46") { return "IPv4+6" }
        if proto.hasSuffix("6") { return "IPv6" }
        return "IPv4"
    }

    /// netstat prints "address.port" (the port after the last dot, for IPv6 too: "::1.8021", "*.22").
    static func splitDotted(_ s: String) -> (String, Int)? {
        guard let dot = s.lastIndex(of: "."), let port = Int(s[s.index(after: dot)...]) else { return nil }
        return (String(s[..<dot]), port)
    }

    /// lsof prints "address:port", IPv6 in brackets ("[::1]:631", "*:5353").
    static func splitColon(_ s: String) -> (String, Int)? {
        guard let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]) else { return nil }
        var a = String(s[..<colon])
        if a.hasPrefix("[") && a.hasSuffix("]") { a = String(a.dropFirst().dropLast()) }
        return (a, port)
    }

    /// Parses `lsof -F pcPn` (p pid, c command, P protocol, n name). Connected sockets ("a->b") are skipped; lsof
    /// doesn't say whether a socket is IPv4 or IPv6 in these fields, so the family is inferred from the address.
    static func parseLsof(_ out: String) -> [ListeningSocket] {
        var res: [ListeningSocket] = []
        var seen = Set<String>()
        var pid: Int32 = 0, cmd = "", proto = ""
        for line in out.split(separator: "\n") {
            guard let f = line.first else { continue }
            let v = String(line.dropFirst())
            switch f {
            case "p": pid = Int32(v) ?? 0
            case "c": cmd = v
            case "P": proto = v
            case "n":
                guard !v.contains("->"), let (addr, port) = splitColon(v) else { continue }
                // "*" is printed for both the IPv4 and the IPv6 wildcard, so it can't be told apart here.
                let fam = addr.contains(":") ? "IPv6" : (addr == "*" ? "IP" : "IPv4")
                let s = ListeningSocket(process: cmd, pid: pid, proto: proto, family: fam, address: addr, port: port)
                if seen.insert(s.id).inserted { res.append(s) }
            default: break
            }
        }
        return res
    }
}
