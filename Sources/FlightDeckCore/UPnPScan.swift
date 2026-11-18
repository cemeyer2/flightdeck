import Foundation
import Darwin

// The UPnP destination's networking: SSDP discovery over a BSD UDP socket, description fetches and the router's
// port-mapping SOAP calls over URLSession. Runs only when the page appears or Refresh is pressed (and the passive NOTIFY
// listener only while the page is visible), never in the background. Every request is read-only: nothing here adds,
// changes or deletes a port mapping.
//
// Safety limits: a description is only fetched from the same IP address that answered the search (so a spoofed or
// malicious reply can't make FlightDeck request arbitrary hosts), with a 3 s timeout and a 512 KB cap; the mapping
// list stops after 256 entries.

/// A root device found by SSDP, with its description (or why it couldn't be read).
public struct UPnPRootDevice: Identifiable, Hashable, Sendable {
    /// One description document is one root device, so its LOCATION identifies it.
    public var id: String { location }
    /// IPv4 address the SSDP reply came from.
    public var ip: String
    public var location: String
    public var uuid: String?
    public var server: String?
    /// Every search target / notification type seen for this device ("upnp:rootdevice", device and service URNs).
    public var targets: [String]
    public var description: UPnPDevice?
    /// Set when the description couldn't be fetched or parsed; the device is still listed, with what SSDP said.
    public var descriptionError: String?

    public init(ip: String, location: String, uuid: String?, server: String?, targets: [String], description: UPnPDevice? = nil, descriptionError: String? = nil) {
        self.ip = ip; self.location = location; self.uuid = uuid; self.server = server; self.targets = targets
        self.description = description; self.descriptionError = descriptionError
    }

    public var category: UPnPCategory { description.map(UPnPCategory.of) ?? .other }
    /// Friendly name, else the model, else the SERVER header, else the IP: the best label available.
    public var displayName: String { description?.friendlyName ?? description?.modelName ?? server ?? ip }
}

/// The router's port mappings and external address, from its WANIPConnection/WANPPPConnection service.
public struct UPnPGatewayReport: Hashable, Sendable {
    /// Which root device (id) and service answered.
    public var deviceID: String
    public var serviceType: String
    public var externalIP: String?
    /// Why the external IP is unknown, when it is.
    public var externalIPError: String?
    public var mappings: [UPnPPortMapping]
    /// Set when listing stopped on something other than the normal end-of-list fault (the list may be incomplete).
    public var mappingsError: String?
    /// True when the 256-entry cap was hit.
    public var truncated = false

    public init(deviceID: String, serviceType: String, externalIP: String?, externalIPError: String? = nil, mappings: [UPnPPortMapping], mappingsError: String? = nil, truncated: Bool = false) {
        self.deviceID = deviceID; self.serviceType = serviceType; self.externalIP = externalIP; self.externalIPError = externalIPError
        self.mappings = mappings; self.mappingsError = mappingsError; self.truncated = truncated
    }
}

/// Plain per-device summary for other features (the network map) to enrich their own device lists with.
/// One entry per root device; fields the device didn't report are nil, never guessed.
public struct UPnPHostInfo: Hashable, Sendable {
    public var ip: String
    public var friendlyName: String?
    public var manufacturer: String?
    /// Model name plus number when both are given ("Archer AX55 v1.0").
    public var model: String?
    /// The root device type URN, e.g. "urn:schemas-upnp-org:device:InternetGatewayDevice:2".
    public var deviceType: String?
    public var category: UPnPCategory
    /// Service type URNs of the device and its embedded devices.
    public var services: [String]
    /// The device's admin page, if it advertises one.
    public var presentationURL: String?
    public var uuid: String?
}

/// The result of one scan.
public struct UPnPScan: Sendable {
    public var devices: [UPnPRootDevice]
    public var gateway: UPnPGatewayReport?
    /// Names for LAN addresses (port-mapping internal clients): this Mac's own addresses map to "This Mac", others to
    /// a UPnP friendly name or reverse-DNS name where one is known. Missing = unknown.
    public var hostNames: [String: String]
    /// This Mac's IPv4 addresses, so the UI can flag mappings that point here.
    public var localAddresses: Set<String>
    /// Set when discovery itself failed (no socket, no interface, Local Network access denied …).
    public var error: String?
    public var finished: Date

    public init(devices: [UPnPRootDevice], gateway: UPnPGatewayReport?, hostNames: [String: String], localAddresses: Set<String>, error: String? = nil, finished: Date = Date()) {
        self.devices = devices; self.gateway = gateway; self.hostNames = hostNames; self.localAddresses = localAddresses
        self.error = error; self.finished = finished
    }

    /// Integration hook for the network map: one plain record per discovered root device, keyed by IP for merging.
    /// A host can run several UPnP root devices (a NAS with a media server and a separate admin service), so the same
    /// IP may appear more than once.
    public var hosts: [UPnPHostInfo] {
        devices.map { d in
            let x = d.description
            let model = [x?.modelName, x?.modelNumber].compactMap { $0 }.joined(separator: " ")
            return UPnPHostInfo(ip: d.ip, friendlyName: x?.friendlyName, manufacturer: x?.manufacturer, model: model.isEmpty ? nil : model,
                                deviceType: x?.deviceType, category: d.category, services: x?.allServices.map(\.serviceType) ?? [],
                                presentationURL: x?.presentationURL, uuid: d.uuid)
        }
    }
}

extension UPnPScan {
    /// Groups SSDP messages into root devices: one per LOCATION, since one description document is one root device.
    /// (Not per USN UUID: a root device announces each embedded device under that device's own UUID, so grouping by
    /// UUID listed a speaker several times.) Keeps the first SERVER seen and every distinct target. `ssdp:byebye`
    /// (which carries no LOCATION) removes the device that announced that UUID. `from` is the sender's IPv4 address.
    public static func group(_ messages: [(message: SSDPMessage, from: String)]) -> [UPnPRootDevice] {
        var order: [String] = []
        var byLocation: [String: UPnPRootDevice] = [:]
        var uuids: [String: Set<String>] = [:]   // location → every UUID announced from it
        for (m, ip) in messages where m.kind != .search {
            if m.nts?.lowercased() == "ssdp:byebye" {
                guard let u = m.uuid else { continue }
                for (loc, set) in uuids where set.contains(u) { byLocation[loc] = nil; order.removeAll { $0 == loc }; uuids[loc] = nil }
                continue
            }
            guard let loc = m.location, !loc.isEmpty else { continue }
            if let u = m.uuid { uuids[loc, default: []].insert(u) }
            if var d = byLocation[loc] {
                if let t = m.searchTarget, !d.targets.contains(t) { d.targets.append(t) }
                if d.server == nil { d.server = m.server }
                // The root device's UUID is the one announced with "upnp:rootdevice"; until seen, the first UUID stands in.
                if m.searchTarget == "upnp:rootdevice", let u = m.uuid { d.uuid = u }
                byLocation[loc] = d
            } else {
                order.append(loc)
                byLocation[loc] = UPnPRootDevice(ip: ip, location: loc, uuid: m.uuid, server: m.server, targets: m.searchTarget.map { [$0] } ?? [])
            }
        }
        return order.compactMap { byLocation[$0] }
    }

    /// Every UUID a device may say goodbye with: the root's and its embedded devices' (UDN "uuid:…").
    static func uuids(of d: UPnPRootDevice) -> Set<String> {
        var s = Set(d.uuid.map { [$0] } ?? [])
        for x in d.description?.allDevices ?? [] { if let u = x.udn { s.insert(u.hasPrefix("uuid:") ? String(u.dropFirst(5)) : u) } }
        return s
    }
}

// MARK: - Running a scan

extension UPnPScan {
    /// Description documents are small (a few KB); anything larger is refused rather than parsed.
    static let maxDescriptionBytes = 512 * 1024
    /// A safety stop for routers that never return the end-of-list fault.
    static let maxMappings = 256

    /// Discovers, describes and (for a gateway) lists port mappings. Blocking, roughly `listen` + a few seconds; call off
    /// the main thread. Read-only.
    public static func run(listen: TimeInterval = 3) -> UPnPScan {
        let local = SSDPSocket.localAddresses()
        let (datagrams, err) = SSDPSocket.search(listen: listen)
        let messages = datagrams.compactMap { d in SSDP.parse(d.text).map { (message: $0, from: d.from) } }
        var devices = group(messages)
        describe(&devices)
        return finish(devices, local: local, error: err)
    }

    /// Adds devices announced by NOTIFY since the scan (describing only the new ones), drops those that said
    /// `ssdp:byebye`, and rebuilds the gateway report and names. Blocking; call off the main thread.
    public static func merging(_ scan: UPnPScan, announcements: [(message: SSDPMessage, from: String)]) -> UPnPScan {
        var devices = scan.devices
        let known = Set(devices.map(\.id))
        let byebye = Set(announcements.filter { $0.message.nts?.lowercased() == "ssdp:byebye" }.compactMap { $0.message.uuid })
        devices.removeAll { !uuids(of: $0).isDisjoint(with: byebye) }
        var fresh = group(announcements).filter { !known.contains($0.id) }
        describe(&fresh)
        devices += fresh
        return finish(devices, local: scan.localAddresses, error: scan.error)
    }

    /// Sorts devices, lists the gateway's mappings and names the LAN addresses involved.
    static func finish(_ devices: [UPnPRootDevice], local: Set<String>, error: String?) -> UPnPScan {
        var devices = devices
        devices.sort { ($0.category, $0.displayName.lowercased()) < ($1.category, $1.displayName.lowercased()) }
        let gw = gatewayReport(devices)
        var names: [String: String] = [:]
        for d in devices { if let n = d.description?.friendlyName, names[d.ip] == nil { names[d.ip] = n } }
        let clients = Set(gw?.mappings.compactMap(\.internalClient) ?? [])
        for (ip, n) in reverseDNS(clients.subtracting(names.keys).subtracting(local)) { names[ip] = n }
        for ip in local { names[ip] = "This Mac" }
        return UPnPScan(devices: devices, gateway: gw, hostNames: names, localAddresses: local, error: error)
    }

    /// Fetches every device's description concurrently (each with its own timeout).
    static func describe(_ devices: inout [UPnPRootDevice]) {
        let snapshot = devices
        let results = LockedBox([(UPnPDevice?, String?)](repeating: (nil, nil), count: snapshot.count))
        DispatchQueue.concurrentPerform(iterations: snapshot.count) { i in
            let r = fetchDescription(snapshot[i])
            results.with { $0[i] = r }
        }
        let r = results.with { $0 }
        for i in devices.indices { (devices[i].description, devices[i].descriptionError) = r[i] }
    }

    static func fetchDescription(_ d: UPnPRootDevice) -> (UPnPDevice?, String?) {
        guard let url = URL(string: d.location), let host = url.host, url.scheme == "http" || url.scheme == "https" else {
            return (nil, "LOCATION isn't an http URL")
        }
        // Only follow LOCATIONs on the device that answered: no third-party hosts (see the file comment).
        guard host == d.ip else { return (nil, "LOCATION points at \(host), not the device that answered (\(d.ip)); not fetched") }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.setValue("FlightDeck UPnP/1.1", forHTTPHeaderField: "User-Agent")
        switch HTTP.fetch(req, cap: maxDescriptionBytes) {
        case .failure(let e): return (nil, e.reason)
        case .success(let data):
            guard let desc = UPnP.parseDescription(data, location: d.location) else { return (nil, "LOCATION didn't return a UPnP device description (not UPnP XML)") }
            return (desc.root, nil)
        }
    }

    /// Lists port mappings from the first gateway with a WAN connection service. Read-only SOAP calls only
    /// (GetExternalIPAddress, GetGenericPortMappingEntry); the control URL must be on the gateway itself.
    static func gatewayReport(_ devices: [UPnPRootDevice]) -> UPnPGatewayReport? {
        for d in devices where d.category == .gateway {
            guard let svc = d.description?.allServices.first(where: { IGD.isWANConnection($0.serviceType) }),
                  let ctl = svc.controlURL.flatMap(URL.init(string:)), ctl.host == d.ip else { continue }
            var report = UPnPGatewayReport(deviceID: d.id, serviceType: svc.serviceType, externalIP: nil, mappings: [])
            func describeFault(_ c: Int?, _ m: String?) -> String { (m ?? "error") + (c.map { " (\($0))" } ?? "") }
            switch soap(ctl, svc.serviceType, "GetExternalIPAddress") {
            case .values(let v):
                report.externalIP = v["NewExternalIPAddress"].flatMap { $0.isEmpty ? nil : $0 }
                if report.externalIP == nil { report.externalIPError = "the router returned no address" }
            case .fault(let c, let m): report.externalIPError = "the router refused: " + describeFault(c, m)
            case nil: report.externalIPError = "no valid SOAP reply from the router"
            }
            // Entries are numbered from 0; the router answers past the last one with a fault (713).
            for i in 0..<maxMappings {
                let r = soap(ctl, svc.serviceType, "GetGenericPortMappingEntry", [("NewPortMappingIndex", "\(i)")])
                if case .values(let v) = r, let m = IGD.mapping(from: v) { report.mappings.append(m); continue }
                if case .fault(let c, let m) = r {
                    if !IGD.isEndOfList(c) { report.mappingsError = "listing stopped at entry \(i): " + describeFault(c, m) }
                } else {
                    report.mappingsError = "listing stopped at entry \(i): no valid SOAP reply"
                }
                break
            }
            report.truncated = report.mappings.count == maxMappings
            return report
        }
        return nil
    }

    /// One SOAP call; nil when there was no parseable reply (timeout, refused, not XML).
    static func soap(_ url: URL, _ serviceType: String, _ action: String, _ args: [(String, String)] = []) -> SOAPResult? {
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = Data(IGD.envelope(action: action, serviceType: serviceType, args: args).utf8)
        // A fault arrives as HTTP 500 with a SOAP body, so the status isn't checked: the body decides.
        guard case .success(let data) = HTTP.fetch(req, cap: 64 * 1024, acceptAnyStatus: true) else { return nil }
        return IGD.parseSOAP(data)
    }

    /// Reverse DNS (which on macOS also asks mDNS for .local names) for each address, concurrently, giving up on the
    /// stragglers after 2 s. Addresses without a name are left out.
    static func reverseDNS(_ ips: Set<String>) -> [String: String] {
        let box = LockedBox([String: String]())
        let g = DispatchGroup()
        for ip in ips {
            DispatchQueue.global().async(group: g) {
                var sin = sockaddr_in(); sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); sin.sin_family = sa_family_t(AF_INET)
                guard inet_pton(AF_INET, ip, &sin.sin_addr) == 1 else { return }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let r = withUnsafePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) } }
                guard r == 0 else { return }
                let name = String(cString: host)
                box.with { $0[ip] = name.hasSuffix(".") ? String(name.dropLast()) : name }
            }
        }
        _ = g.wait(timeout: .now() + 2)
        return box.with { $0 }
    }
}

/// A lock-protected value shared with concurrent closures.
final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func with<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

/// Synchronous HTTP for the scan (already off the main thread): an ephemeral session (no cookies or cache), the request's
/// timeout, and a byte cap enforced while receiving so a misbehaving device can't feed us megabytes.
enum HTTP {
    struct Failure: Error { var reason: String }

    static func fetch(_ req: URLRequest, cap: Int, acceptAnyStatus: Bool = false) -> Result<Data, Failure> {
        let delegate = CappedDelegate(cap: cap)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForResource = req.timeoutInterval + 1
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: req).resume()
        guard delegate.done.wait(timeout: .now() + req.timeoutInterval + 2) == .success else { return .failure(Failure(reason: "timed out")) }
        return delegate.result(acceptAnyStatus: acceptAnyStatus)
    }

    /// Accumulates the body, cancelling once it exceeds the cap. Callbacks arrive on the session's serial queue, and
    /// `result` is read only after `done` is signalled, so the fields need no further locking.
    final class CappedDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let cap: Int
        let done = DispatchSemaphore(value: 0)
        private var data = Data(), status = 0, error: String?
        init(cap: Int) { self.cap = cap }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            self.data.append(data)
            if self.data.count > cap { error = "reply larger than \(cap / 1024) KB; not read"; dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
            status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil, let e { error = e.localizedDescription }
            done.signal()
        }
        func result(acceptAnyStatus: Bool) -> Result<Data, Failure> {
            if let error { return .failure(Failure(reason: error)) }
            if !acceptAnyStatus && !(200..<300).contains(status) { return .failure(Failure(reason: "HTTP \(status)")) }
            return .success(data)
        }
    }
}

/// The root devices at one IP address: what the UPnP map draws as one node. A TV or NAS often runs several root devices
/// (a media renderer, a DIAL server for casting, a vendor service), each with its own description.
public struct UPnPHostGroup: Identifiable, Hashable, Sendable {
    public var id: String { ip }
    public var ip: String
    public var roots: [UPnPRootDevice]
    /// The most specific category among the roots (a TV's MediaRenderer beats its DIAL server's "other").
    public var category: UPnPCategory { roots.map(\.category).min() ?? .other }
    /// The friendly name of the root that decided the category, else the first name available.
    public var displayName: String {
        (roots.first { $0.category == category && $0.description?.friendlyName != nil } ?? roots.first)?.displayName ?? ip
    }
}

extension UPnPScan {
    /// Root devices grouped by IP, ordered by category then name.
    public var byHost: [UPnPHostGroup] {
        var order: [String] = [], map: [String: [UPnPRootDevice]] = [:]
        for d in devices { if map[d.ip] == nil { order.append(d.ip) }; map[d.ip, default: []].append(d) }
        return order.map { UPnPHostGroup(ip: $0, roots: map[$0] ?? []) }
            .sorted { ($0.category, $0.displayName.lowercased()) < ($1.category, $1.displayName.lowercased()) }
    }
}
