import Foundation

// Network map, part 7: the two things that send packets, both run only when the user presses their button.
// The active scan sends one ICMP echo ("ping") to every address of this Mac's subnet (at most a /24), paced at
// 50 per second. Whether or not a device answers the ping, the kernel has to look it up with ARP first, so the ARP
// table afterwards lists every device that is on and connected, including phones that ignore pings. Traceroute runs
// the system `traceroute` toward one internet host.

public enum ActiveScan {
    /// The addresses an active scan of `net` would ping: every host address of the subnet, or of the /24 around this
    /// Mac's address when the subnet is larger (a /16 would be 65,000 pings). Excludes the network, broadcast and
    /// this Mac's own address. Empty for /31 and /32.
    public static func targets(for net: IPv4Net) -> [String] {
        guard let a = IPv4.parse(net.address), net.prefix <= 30 else { return [] }
        let prefix = max(net.prefix, 24)
        let m = IPv4.mask(prefix), base = a & m, last = base | ~m
        return (base + 1 ..< last).filter { $0 != a }.map(IPv4.string)
    }

    /// Pings each target once through an unprivileged ICMP datagram socket (no root needed on macOS), `interval`
    /// seconds apart, then waits `settle` seconds for ARP replies. Replies aren't read: the result that matters is
    /// what lands in the ARP table, which the caller re-reads. Returns the number of pings sent and the first send
    /// error, if any (e.g. "No route to host" when macOS's Local Network permission is denied).
    public static func run(_ targets: [String], interval: TimeInterval = 0.02, settle: TimeInterval = 2) -> (sent: Int, error: String?) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return (0, String(cString: strerror(errno))) }
        defer { close(fd) }
        var sent = 0, firstError: String?
        let ident = UInt16(truncatingIfNeeded: getpid())
        for (seq, ip) in targets.enumerated() {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { continue }
            var packet = echoRequest(id: ident, seq: UInt16(truncatingIfNeeded: seq))
            let n = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, &packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if n >= 0 { sent += 1 } else if firstError == nil { firstError = String(cString: strerror(errno)) }
            Thread.sleep(forTimeInterval: interval)
        }
        Thread.sleep(forTimeInterval: settle)
        return (sent, firstError)
    }

    /// An ICMP echo request (type 8) with an 8-byte payload and the internet checksum filled in. (The kernel
    /// rewrites the identifier on datagram ICMP sockets, but the checksum must still be valid.)
    static func echoRequest(id: UInt16, seq: UInt16) -> [UInt8] {
        var b: [UInt8] = [8, 0, 0, 0, UInt8(id >> 8), UInt8(id & 0xff), UInt8(seq >> 8), UInt8(seq & 0xff)] + Array("FlightDk".utf8)
        let sum = checksum(b)
        b[2] = UInt8(sum >> 8); b[3] = UInt8(sum & 0xff)
        return b
    }

    /// RFC 1071 ones'-complement sum of 16-bit words.
    static func checksum(_ b: [UInt8]) -> UInt16 {
        var s: UInt32 = 0
        var i = 0
        while i + 1 < b.count { s += UInt32(b[i]) << 8 | UInt32(b[i + 1]); i += 2 }
        if i < b.count { s += UInt32(b[i]) << 8 }
        while s >> 16 != 0 { s = (s & 0xffff) + (s >> 16) }
        return ~UInt16(s)
    }
}

extension Traceroute {
    /// Runs `/usr/sbin/traceroute -n -q 1 -w 1 -m 16 host` (numeric, one probe per hop, 1 s wait, at most 16 hops;
    /// Shell.run gives up after 30 s). Returns nil if traceroute couldn't run.
    public static func run(to host: String) -> [TraceHop]? {
        guard let out = Shell.run("/usr/sbin/traceroute", ["-n", "-q", "1", "-w", "1", "-m", "16", host], timeout: 30) else { return nil }
        // Trailing silent hops are dropped: they are only probes timing out past the last router that answers.
        var hops = parse(out)
        while let l = hops.last, l.ip == nil { hops.removeLast() }
        return hops
    }
}
