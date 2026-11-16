import Foundation
import Darwin

public struct InterfaceSample: Codable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var inBps: Double
    public var outBps: Double
    public var totalIn: UInt64
    public var totalOut: UInt64
    public var linkSpeed: UInt64
    public var isUp: Bool
    public var addresses: [String]
    public var mac: String?
}

public struct NetworkSample: Codable, Sendable {
    public var inBps: Measured<Double>
    public var outBps: Measured<Double>
    public var totalIn: UInt64
    public var totalOut: UInt64
    public var interfaces: [InterfaceSample]
}

public final class NetworkSampler {
    private var previous: [String: (UInt64, UInt64)] = [:]
    private var lastTime: Date?
    public init() {}

    struct Raw { var ib: UInt64; var ob: UInt64; var speed: UInt64; var up: Bool }

    private func readCounters() -> [String: Raw] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
        var out: [String: Raw] = [:]
        buf.withUnsafeBytes { raw in
            var off = 0
            while off < len {
                let hdr = raw.baseAddress!.advanced(by: off).assumingMemoryBound(to: if_msghdr.self)
                let msglen = Int(hdr.pointee.ifm_msglen)
                if msglen == 0 { break }
                if Int32(hdr.pointee.ifm_type) == RTM_IFINFO2 {
                    let h2 = raw.baseAddress!.advanced(by: off).assumingMemoryBound(to: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(h2.pointee.ifm_index), &nameBuf) != nil {
                        let name = String(cString: nameBuf)
                        let d = h2.pointee.ifm_data
                        // NET_RT_IFLIST2 truncates byte counters to 32 bits (they wrap every 4 GB), so read
                        // the full 64-bit counters from the interface MIB, as netstat does.
                        let full = Self.counters64(index: Int32(h2.pointee.ifm_index))
                        out[name] = Raw(ib: full?.0 ?? d.ifi_ibytes, ob: full?.1 ?? d.ifi_obytes, speed: d.ifi_baudrate,
                                        up: (h2.pointee.ifm_flags & IFF_UP) != 0)
                    }
                }
                off += msglen
            }
        }
        return out
    }

    static func counters64(index: Int32) -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
        var d = ifmibdata(); var len = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, 6, &d, &len, nil, 0) == 0 else { return nil }
        return (d.ifmd_data.ifi_ibytes, d.ifmd_data.ifi_obytes)
    }

    private func addresses() -> ([String: [String]], [String: String]) {
        var addrs: [String: [String]] = [:]; var macs: [String: String] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return ([:], [:]) }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let ifa = p {
            let name = String(cString: ifa.pointee.ifa_name)
            if let sa = ifa.pointee.ifa_addr {
                let fam = Int32(sa.pointee.sa_family)
                if fam == AF_INET || fam == AF_INET6 {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let slen = socklen_t(fam == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
                    if getnameinfo(sa, slen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        addrs[name, default: []].append(String(cString: host))
                    }
                } else if fam == AF_LINK {
                    let sdl = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_dl.self)
                    if sdl.pointee.sdl_alen == 6 {
                        let base = UnsafeRawPointer(sa).advanced(by: 8 + Int(sdl.pointee.sdl_nlen))
                        let bytes = (0..<6).map { base.load(fromByteOffset: $0, as: UInt8.self) }
                        macs[name] = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                    }
                }
            }
            p = ifa.pointee.ifa_next
        }
        return (addrs, macs)
    }

    public func sample() -> NetworkSample {
        let now = Date()
        let cur = readCounters()
        let (addrs, macs) = addresses()
        let dt = lastTime.map { max(now.timeIntervalSince($0), 0.001) }
        var ifs: [InterfaceSample] = []
        var ti = 0.0, to = 0.0, si: UInt64 = 0, so: UInt64 = 0
        for (name, r) in cur.sorted(by: { $0.key < $1.key }) {
            var ib = 0.0, ob = 0.0
            if let dt, let p = previous[name] {
                ib = r.ib >= p.0 ? Double(r.ib - p.0) / dt : 0   // counter reset: no invented spike
                ob = r.ob >= p.1 ? Double(r.ob - p.1) / dt : 0
            }
            if !name.hasPrefix("lo") { ti += ib; to += ob; si += r.ib; so += r.ob }
            ifs.append(InterfaceSample(name: name, inBps: ib, outBps: ob, totalIn: r.ib, totalOut: r.ob,
                                       linkSpeed: r.speed, isUp: r.up, addresses: addrs[name] ?? [], mac: macs[name]))
        }
        let warm = dt != nil && !previous.isEmpty
        previous = cur.mapValues { ($0.ib, $0.ob) }; lastTime = now
        return NetworkSample(inBps: warm ? .value(ti) : .unavailable("warming up"),
                             outBps: warm ? .value(to) : .unavailable("warming up"),
                             totalIn: si, totalOut: so, interfaces: ifs)
    }
}
