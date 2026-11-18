import Foundation
import Network
import dnssd

// Network map, part 6: Bonjour (mDNS / DNS-SD) discovery. NWBrowser finds service instances and their TXT records;
// each instance is then resolved with the DNS-SD C API (DNSServiceResolve for the host name, DNSServiceGetAddrInfo
// for its addresses). Resolving through mDNSResponder doesn't open a connection to the device, which NWConnection
// would. One `browse` call runs for a few seconds and then stops everything it started: there is no background
// browsing.

public enum BonjourBrowser {
    /// Service types worth browsing on a home or office network, with what they usually mean.
    public static let serviceTypes = [
        "_airplay._tcp", "_raop._tcp", "_googlecast._tcp", "_spotify-connect._tcp", "_sonos._tcp", "_amzn-wplay._tcp",
        "_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp", "_uscan._tcp", "_scanner._tcp",
        "_smb._tcp", "_afpovertcp._tcp", "_ssh._tcp", "_sftp-ssh._tcp", "_rfb._tcp",
        "_hap._tcp", "_hap._udp", "_homekit._tcp", "_matter._tcp", "_hue._tcp",
        "_companion-link._tcp", "_device-info._tcp", "_http._tcp", "_https._tcp",
    ]

    /// Browses `types` for `browseTime` seconds, then resolves each instance found (all in parallel, up to
    /// `resolveTime` more seconds). Blocks the calling thread; call it off the main thread. Services that didn't
    /// resolve in time are returned without addresses (and so can't be tied to a device).
    public static func browse(types: [String] = serviceTypes, browseTime: TimeInterval = 3, resolveTime: TimeInterval = 2.5) -> [BonjourService] {
        let queue = DispatchQueue(label: "flightdeck.bonjour")
        final class Found: @unchecked Sendable { var items: [String: BonjourService] = [:]; var ifIndex: [String: UInt32] = [:] }
        let found = Found()   // only touched on `queue`
        var browsers: [NWBrowser] = []
        for t in types {
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: t, domain: "local."), using: .init())
            b.browseResultsChangedHandler = { results, _ in
                for r in results {
                    guard case let .service(name, type, _, interface) = r.endpoint else { continue }
                    var txt: [String: String] = [:]
                    if case let .bonjour(rec) = r.metadata { txt = rec.dictionary }
                    let ifc = interface ?? r.interfaces.first
                    let key = "\(name)|\(type)"
                    let typeName = type.hasSuffix(".") ? String(type.dropLast()) : type
                    found.items[key] = BonjourService(name: name, type: typeName, interface: ifc?.name, txt: txt)
                    if let i = ifc?.index { found.ifIndex[key] = UInt32(i) }
                }
            }
            b.start(queue: queue)
            browsers.append(b)
        }
        Thread.sleep(forTimeInterval: browseTime)
        let snapshot: [(String, BonjourService, UInt32)] = queue.sync {
            browsers.forEach { $0.cancel() }
            return found.items.map { ($0.key, $0.value, found.ifIndex[$0.key] ?? 0) }
        }
        // Resolve every instance at once; each resolver writes its result back under the lock.
        let lock = NSLock()
        var resolved: [String: BonjourService] = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.0, $0.1) })
        let resolvers = snapshot.map { key, svc, ifIndex in
            Resolver(service: svc, ifIndex: ifIndex) { r in lock.lock(); resolved[key] = r; lock.unlock() }
        }
        resolvers.forEach { $0.start() }
        Thread.sleep(forTimeInterval: snapshot.isEmpty ? 0 : resolveTime)
        resolvers.forEach { $0.stop() }
        lock.lock(); defer { lock.unlock() }
        return resolved.values.sorted { ($0.type, $0.name) < ($1.type, $1.name) }
    }
}

/// Resolves one service instance to its host and addresses with DNS-SD, on its own serial queue. The C callbacks
/// can't capture context, so `self` travels through the context pointer (retained while the resolver runs; `stop`
/// must be called exactly once, which `browse` does).
final class Resolver: @unchecked Sendable {
    private var service: BonjourService
    private let ifIndex: UInt32
    private let update: (BonjourService) -> Void
    private let queue = DispatchQueue(label: "flightdeck.bonjour.resolve")
    private var resolveRef: DNSServiceRef?
    private var addrRef: DNSServiceRef?
    private var retained: Unmanaged<Resolver>?

    init(service: BonjourService, ifIndex: UInt32, update: @escaping (BonjourService) -> Void) {
        self.service = service; self.ifIndex = ifIndex; self.update = update
    }

    func start() {
        queue.async { [self] in
            let ctx = Unmanaged.passRetained(self); retained = ctx
            var ref: DNSServiceRef?
            let err = DNSServiceResolve(&ref, 0, ifIndex, service.name, service.type, "local.", { _, _, _, err, _, host, _, _, _, ctx in
                guard err == kDNSServiceErr_NoError, let ctx, let host else { return }
                Unmanaged<Resolver>.fromOpaque(ctx).takeUnretainedValue().resolved(host: String(cString: host))
            }, ctx.toOpaque())
            guard err == kDNSServiceErr_NoError, let ref else { return }
            resolveRef = ref
            DNSServiceSetDispatchQueue(ref, queue)
        }
    }

    /// Called on `queue` with the target host ("Living-Room.local."); asks for its IPv4 and IPv6 addresses.
    private func resolved(host: String) {
        guard addrRef == nil, let ctx = retained else { return }
        service.host = host; update(service)
        var ref: DNSServiceRef?
        let err = DNSServiceGetAddrInfo(&ref, 0, ifIndex, DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6), host,
                                        { _, _, _, err, _, addr, _, ctx in
            guard err == kDNSServiceErr_NoError, let ctx, let addr else { return }
            Unmanaged<Resolver>.fromOpaque(ctx).takeUnretainedValue().gotAddress(addr)
        }, ctx.toOpaque())
        guard err == kDNSServiceErr_NoError, let ref else { return }
        addrRef = ref
        DNSServiceSetDispatchQueue(ref, queue)
    }

    private func gotAddress(_ sa: UnsafePointer<sockaddr>) {
        guard let ip = NetworkDiscovery.numericHost(sa) else { return }
        let a = String(ip.split(separator: "%")[0])
        if !service.addresses.contains(a) { service.addresses.append(a); update(service) }
    }

    /// Deallocates the DNS-SD operations (on their queue, so no callback runs afterwards) and releases `self`.
    func stop() {
        queue.sync {
            if let r = addrRef { DNSServiceRefDeallocate(r) }
            if let r = resolveRef { DNSServiceRefDeallocate(r) }
            addrRef = nil; resolveRef = nil
            retained?.release(); retained = nil
        }
    }
}
