import Foundation
import Darwin

// SSDP over BSD UDP sockets. BSD sockets rather than Network.framework because the search must go out on every IPv4
// interface (a Mac on Wi-Fi and Ethernet has a router on each) and the replies are plain unicast datagrams to our
// ephemeral port, which a single blocking socket with poll() handles simply and synchronously off the main thread.
//
// macOS 15+ asks the user for Local Network access the first time an app sends multicast; until it's granted, sendto()
// fails with EHOSTUNREACH or EPERM, which is reported as such rather than as "no devices".

public enum SSDPSocket {
    /// One received datagram and the IPv4 address it came from.
    public typealias Datagram = (text: String, from: String)

    /// Non-loopback, up, multicast-capable IPv4 interfaces: name and address.
    public static func ipv4Interfaces() -> [(name: String, address: in_addr)] {
        var out: [(String, in_addr)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [] }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_MULTICAST != 0 else { continue }
            let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
            out.append((String(cString: ifa.pointee.ifa_name), sin.sin_addr))
        }
        return out
    }

    /// This Mac's IPv4 addresses (all interfaces, loopback excluded), as dotted strings.
    public static func localAddresses() -> Set<String> { Set(ipv4Interfaces().map { ntoa($0.address) }) }

    static func ntoa(_ a: in_addr) -> String {
        var a = a
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    static func groupAddress() -> sockaddr_in {
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = SSDP.port.bigEndian
        inet_pton(AF_INET, SSDP.multicastAddress, &to.sin_addr)
        return to
    }

    /// Sends M-SEARCHes for each target on every IPv4 interface (twice, as UDP may drop one), then collects replies for
    /// `listen` seconds. Blocking. Returns the datagrams, or an error string if nothing could be sent at all.
    public static func search(targets: [String] = ["ssdp:all", "upnp:rootdevice"], listen: TimeInterval = 3) -> (datagrams: [Datagram], error: String?) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return ([], "couldn't open a UDP socket (\(String(cString: strerror(errno))))") }
        defer { close(fd) }
        var ttl: UInt8 = 2   // SSDP's recommended TTL: stay on the local network
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var any = sockaddr_in()
        any.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); any.sin_family = sa_family_t(AF_INET)
        _ = withUnsafePointer(to: &any) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }

        let interfaces = ipv4Interfaces()
        guard !interfaces.isEmpty else { return ([], "no active IPv4 network interface") }
        var to = groupAddress()
        var sent = 0, lastError: Int32 = 0
        for round in 0..<2 {
            if round == 1 { usleep(150_000) }
            for i in interfaces {
                var a = i.address   // choose the outgoing interface for the multicast
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &a, socklen_t(MemoryLayout<in_addr>.size))
                for t in targets {
                    let msg = Array(SSDP.search(target: t).utf8)
                    let n = withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                    if n >= 0 { sent += 1 } else { lastError = errno }
                }
            }
        }
        guard sent > 0 else {
            let why = String(cString: strerror(lastError))
            let hint = lastError == EHOSTUNREACH || lastError == EPERM ? " (is Local Network access allowed for FlightDeck in System Settings › Privacy & Security?)" : ""
            return ([], "couldn't send the SSDP search: \(why)\(hint)")
        }
        return (receive(fd, until: Date().addingTimeInterval(listen)), nil)
    }

    /// Reads datagrams from `fd` until the deadline (poll() with the remaining time, so it never blocks past it).
    static func receive(_ fd: Int32, until deadline: Date, stop: (() -> Bool)? = nil) -> [Datagram] {
        var out: [Datagram] = []
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 || stop?() == true { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, Int32(min(left, 0.25) * 1000) + 1)   // wake at least every 0.25 s to check `stop`
            if r < 0 && errno != EINTR { break }
            guard r > 0 else { continue }
            var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) } }
            guard n > 0 else { continue }
            if let s = String(bytes: buf[0..<n], encoding: .utf8) ?? String(bytes: buf[0..<n], encoding: .isoLatin1) {
                out.append((s, ntoa(from.sin_addr)))
            }
        }
        return out
    }
}

/// Passive NOTIFY listener for while the UPnP page is visible: joins the SSDP group on port 1900 (shared with any other
/// SSDP software via SO_REUSEPORT) and hands each announcement to `onMessage` on the main queue. `stop()` (or deinit)
/// closes the socket; the receive thread holds the listener, so it must be stopped explicitly. Failure to bind just means no passive updates; Refresh still works.
public final class SSDPListener: @unchecked Sendable {
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var stopped = false
    /// Why listening couldn't start, if it couldn't.
    public private(set) var error: String?

    public init(onMessage: @escaping @Sendable (SSDPMessage, String) -> Void) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { error = "no socket"; return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = SSDP.port.bigEndian
        let b = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard b == 0 else { error = "couldn't listen on port 1900 (\(String(cString: strerror(errno))))"; close(fd); return }
        let group = SSDPSocket.groupAddress().sin_addr
        for i in SSDPSocket.ipv4Interfaces() {   // join on every interface, like the search
            var m = ip_mreq(imr_multiaddr: group, imr_interface: i.address)
            setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &m, socklen_t(MemoryLayout<ip_mreq>.size))
        }
        self.fd = fd
        Thread.detachNewThread { [self] in
            while !isStopped {
                for d in SSDPSocket.receive(fd, until: Date().addingTimeInterval(1), stop: { self.isStopped }) {
                    if let m = SSDP.parse(d.text), m.kind == .notify { DispatchQueue.main.async { onMessage(m, d.from) } }
                }
            }
            close(fd)
        }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    /// Stops listening; the receive thread closes the socket within about a quarter second.
    public func stop() { lock.lock(); stopped = true; lock.unlock() }
}
