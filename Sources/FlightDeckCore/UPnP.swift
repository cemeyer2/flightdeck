import Foundation

// The UPnP destination's data model and pure parsers: SSDP messages (search responses and NOTIFY announcements), device
// description XML, device-type classification, and the router's (IGD) SOAP port-mapping replies. Everything here is
// network-free so it can be unit-tested with captured samples; the networking lives in UPnPScan.swift.
//
// UPnP in one paragraph: a device answers an SSDP M-SEARCH (HTTP-over-UDP multicast to 239.255.255.250:1900) with a
// LOCATION URL. That URL serves an XML "device description" naming the device and listing its services, each with a
// control URL that accepts SOAP calls. A router that implements the Internet Gateway Device (IGD) profile exposes a
// WANIPConnection or WANPPPConnection service, whose GetGenericPortMappingEntry action lists the port forwardings
// apps on the LAN have opened through it ("punched holes") without the user configuring anything.

// MARK: - SSDP

/// One SSDP message: a unicast reply to our M-SEARCH (`HTTP/1.1 200 OK`) or a multicast `NOTIFY` announcement.
public struct SSDPMessage: Hashable, Sendable {
    public enum Kind: String, Sendable { case response, notify, search }
    public var kind: Kind
    /// Header names upper-cased (SSDP headers are case-insensitive and devices vary), values trimmed.
    public var headers: [String: String]

    /// URL of the device description XML.
    public var location: String? { headers["LOCATION"] }
    /// Search target (responses) or notification type (NOTIFY uses NT for the same thing).
    public var searchTarget: String? { headers["ST"] ?? headers["NT"] }
    /// Unique service name, e.g. "uuid:…::urn:schemas-upnp-org:device:MediaRenderer:1".
    public var usn: String? { headers["USN"] }
    /// "OS/version UPnP/1.0 product/version", as the device chooses to describe itself.
    public var server: String? { headers["SERVER"] }
    /// NOTIFY sub-type: "ssdp:alive", "ssdp:byebye" or "ssdp:update".
    public var nts: String? { headers["NTS"] }
    /// The device UUID from the USN ("uuid:abc::urn:…" → "abc"), which groups a device's many announcements.
    public var uuid: String? {
        guard let u = usn, u.lowercased().hasPrefix("uuid:") else { return nil }
        let rest = u.dropFirst(5)
        return String(rest.components(separatedBy: "::").first ?? String(rest))
    }
}

public enum SSDP {
    public static let multicastAddress = "239.255.255.250"
    public static let port: UInt16 = 1900

    /// The M-SEARCH request. MX is how many seconds devices may wait (randomly) before answering, so they don't all reply
    /// at once; our listen window must be longer than MX.
    public static func search(target: String, mx: Int = 2) -> String {
        "M-SEARCH * HTTP/1.1\r\nHOST: \(multicastAddress):\(port)\r\nMAN: \"ssdp:discover\"\r\nMX: \(mx)\r\nST: \(target)\r\n" +
            "USER-AGENT: macOS UPnP/1.1 FlightDeck/1.0\r\n\r\n"
    }

    /// Parses one datagram. Returns nil for anything that isn't an SSDP response, NOTIFY or M-SEARCH (our own searches
    /// loop back to the passive listener, which then ignores `.search`).
    public static func parse(_ text: String) -> SSDPMessage? {
        // Lines end in CRLF per spec, but some devices send bare LF.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces).uppercased() else { return nil }
        let kind: SSDPMessage.Kind
        if first.hasPrefix("HTTP/1.") && first.contains(" 200") { kind = .response }
        else if first.hasPrefix("NOTIFY ") { kind = .notify }
        else if first.hasPrefix("M-SEARCH ") { kind = .search }
        else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }   // end of headers
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && headers[name] == nil { headers[name] = value }
        }
        return SSDPMessage(kind: kind, headers: headers)
    }
}

// MARK: - Device descriptions

public struct UPnPIcon: Hashable, Sendable {
    public var mimeType: String?
    public var width: Int?
    public var height: Int?
    /// Absolute URL (resolved against URLBase or the description's location).
    public var url: String?
}

public struct UPnPService: Hashable, Sendable, Identifiable {
    public var id: String { (serviceId ?? "") + "|" + serviceType }
    /// e.g. "urn:schemas-upnp-org:service:WANIPConnection:2".
    public var serviceType: String
    public var serviceId: String?
    /// Absolute URLs, resolved like icons.
    public var controlURL: String?
    public var scpdURL: String?
    public var eventSubURL: String?
    /// "WANIPConnection:2" from the URN, for display.
    public var shortName: String { UPnP.shortType(serviceType) }

    public init(serviceType: String, serviceId: String? = nil, controlURL: String? = nil, scpdURL: String? = nil, eventSubURL: String? = nil) {
        self.serviceType = serviceType; self.serviceId = serviceId; self.controlURL = controlURL; self.scpdURL = scpdURL; self.eventSubURL = eventSubURL
    }
}

/// One device from a description document. Root devices may contain embedded devices (a router's WANDevice holds a
/// WANConnectionDevice; a Sonos ZonePlayer holds a MediaRenderer and a MediaServer), so this is a tree.
public struct UPnPDevice: Hashable, Sendable, Identifiable {
    public var id: String { udn ?? (deviceType + "|" + (friendlyName ?? "")) }
    public var deviceType: String = ""
    public var friendlyName: String?
    public var manufacturer: String?
    public var manufacturerURL: String?
    public var modelName: String?
    public var modelNumber: String?
    public var modelDescription: String?
    public var modelURL: String?
    /// Identifying (it can tie the device to a purchase or warranty), so the UI hides it until asked.
    public var serialNumber: String?
    /// "uuid:…": the device's unique device name.
    public var udn: String?
    /// The device's own web page (admin UI), resolved to an absolute URL.
    public var presentationURL: String?
    public var icons: [UPnPIcon] = []
    public var services: [UPnPService] = []
    public var embedded: [UPnPDevice] = []

    public init(deviceType: String = "") { self.deviceType = deviceType }

    /// This device and every embedded device, depth first.
    public var allDevices: [UPnPDevice] { [self] + embedded.flatMap(\.allDevices) }
    /// Services of this device and all embedded devices.
    public var allServices: [UPnPService] { allDevices.flatMap(\.services) }
    /// "MediaRenderer:1" from the URN, for display.
    public var shortType: String { UPnP.shortType(deviceType) }

    /// The icon best suited to a small badge: PNG preferred (JPEG next), the size closest to 48 px.
    public var bestIcon: UPnPIcon? {
        func rank(_ i: UPnPIcon) -> (Int, Int) {
            let mime = (i.mimeType ?? "").lowercased()
            return (mime.contains("png") ? 0 : mime.contains("jp") ? 1 : 2, abs((i.width ?? 0) - 48))
        }
        return icons.filter { $0.url != nil }.min { rank($0) < rank($1) }
    }
}

/// What a description document said, plus the base used to resolve its relative URLs.
public struct UPnPDescription: Hashable, Sendable {
    public var root: UPnPDevice
    /// The URLBase element (UPnP 1.0; deprecated in 1.1) if present, else the description's own location.
    public var baseURL: String?
}

public enum UPnP {
    /// "urn:schemas-upnp-org:device:MediaRenderer:1" → "MediaRenderer:1". Non-URN strings are returned unchanged.
    public static func shortType(_ urn: String) -> String {
        let parts = urn.split(separator: ":")
        guard parts.count >= 2, urn.lowercased().hasPrefix("urn:") else { return urn }
        return parts.suffix(2).joined(separator: ":")
    }

    /// Resolves a URL from a description against URLBase (when given) or the description's location. Absolute URLs
    /// pass through; relative ones ("/ctl/IPConn", "ctl/IPConn") resolve like links in a web page. Empty → nil.
    public static func resolve(_ s: String?, base: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let u = URL(string: s), u.scheme != nil { return u.absoluteString }
        guard let b = base.flatMap(URL.init(string:)), let u = URL(string: s, relativeTo: b) else { return s }
        return u.absoluteURL.absoluteString
    }

    /// Parses a device description document. `location` is where it was fetched from, used to resolve relative URLs
    /// when there's no URLBase. Returns nil if the XML is malformed or has no root `<device>`.
    public static func parseDescription(_ data: Data, location: String?) -> UPnPDescription? {
        let d = DescriptionParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true   // element names arrive without prefixes, whatever the document uses
        xml.shouldResolveExternalEntities = false   // never fetch anything the document references
        xml.delegate = d
        guard xml.parse(), var root = d.root else { return nil }
        let base = d.urlBase.flatMap { $0.isEmpty ? nil : $0 } ?? location
        func fix(_ dev: inout UPnPDevice) {
            dev.presentationURL = resolve(dev.presentationURL, base: base)
            for i in dev.icons.indices { dev.icons[i].url = resolve(dev.icons[i].url, base: base) }
            for i in dev.services.indices {
                dev.services[i].controlURL = resolve(dev.services[i].controlURL, base: base)
                dev.services[i].scpdURL = resolve(dev.services[i].scpdURL, base: base)
                dev.services[i].eventSubURL = resolve(dev.services[i].eventSubURL, base: base)
            }
            for i in dev.embedded.indices { fix(&dev.embedded[i]) }
        }
        fix(&root)
        return UPnPDescription(root: root, baseURL: base)
    }

    /// XMLParser delegate that builds the device tree. A stack of devices tracks `<deviceList>` nesting: a closing
    /// `</device>` pops the top device and attaches it to its parent (or makes it the root).
    final class DescriptionParser: NSObject, XMLParserDelegate {
        var root: UPnPDevice?
        var urlBase: String?
        private var stack: [UPnPDevice] = []
        private var icon: UPnPIcon?
        private var service: UPnPService?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "device": stack.append(UPnPDevice())
            case "icon": icon = UPnPIcon()
            case "service": service = UPnPService(serviceType: "")
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            // Fields inside <icon> and <service> belong to them, not to the enclosing device.
            if icon != nil {
                switch name {
                case "mimetype": icon?.mimeType = v
                case "width": icon?.width = Int(v)
                case "height": icon?.height = Int(v)
                case "url": icon?.url = v
                case "icon": if let i = icon, !stack.isEmpty { stack[stack.count - 1].icons.append(i) }; icon = nil
                default: break
                }
                return
            }
            if service != nil {
                switch name {
                case "serviceType": service?.serviceType = v
                case "serviceId": service?.serviceId = v
                case "controlURL": service?.controlURL = v
                case "SCPDURL": service?.scpdURL = v
                case "eventSubURL": service?.eventSubURL = v
                case "service": if let s = service, !stack.isEmpty { stack[stack.count - 1].services.append(s) }; service = nil
                default: break
                }
                return
            }
            if name == "URLBase" { urlBase = v; return }
            guard !stack.isEmpty else { return }
            let opt: String? = v.isEmpty ? nil : v
            switch name {
            case "deviceType": stack[stack.count - 1].deviceType = v
            case "friendlyName": stack[stack.count - 1].friendlyName = opt
            case "manufacturer": stack[stack.count - 1].manufacturer = opt
            case "manufacturerURL": stack[stack.count - 1].manufacturerURL = opt
            case "modelName": stack[stack.count - 1].modelName = opt
            case "modelNumber": stack[stack.count - 1].modelNumber = opt
            case "modelDescription": stack[stack.count - 1].modelDescription = opt
            case "modelURL": stack[stack.count - 1].modelURL = opt
            case "serialNumber": stack[stack.count - 1].serialNumber = opt
            case "UDN": stack[stack.count - 1].udn = opt
            case "presentationURL": stack[stack.count - 1].presentationURL = opt
            case "device":
                let d = stack.removeLast()
                if stack.isEmpty { if root == nil { root = d } } else { stack[stack.count - 1].embedded.append(d) }
            default: break
            }
        }
    }
}

// MARK: - Classification

/// The groups the UPnP map arranges devices into.
public enum UPnPCategory: String, CaseIterable, Sendable, Comparable {
    case gateway = "Gateways", mediaRenderer = "Media renderers", mediaServer = "Media servers", printer = "Printers", other = "Other"
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    /// Classifies a root device by the types of it and its embedded devices, and their services. Order matters: a router
    /// that also serves media (many do, for a USB disk) is still a gateway; a speaker that embeds both a MediaRenderer and
    /// a MediaServer (Sonos does) is a renderer, since playing is what it's for.
    public static func of(_ root: UPnPDevice) -> UPnPCategory {
        let types = root.allDevices.map { $0.deviceType.lowercased() }
        let services = root.allServices.map { $0.serviceType.lowercased() }
        func has(_ s: String) -> Bool { types.contains { $0.contains(s) } }
        if has(":internetgatewaydevice:") || has(":wandevice:") || services.contains(where: { $0.contains(":wanipconnection:") || $0.contains(":wanpppconnection:") }) {
            return .gateway
        }
        if has(":mediarenderer:") || services.contains(where: { $0.contains(":avtransport:") || $0.contains(":renderingcontrol:") }) { return .mediaRenderer }
        if has(":mediaserver:") || services.contains(where: { $0.contains(":contentdirectory:") }) { return .mediaServer }
        if has(":printer:") || has(":printbasic:") || services.contains(where: { $0.contains(":printbasic:") || $0.contains(":printenhanced:") }) { return .printer }
        return .other
    }
}

// MARK: - IGD port mappings (SOAP)

/// One port forwarding on the router, from GetGenericPortMappingEntry.
public struct UPnPPortMapping: Hashable, Sendable, Identifiable {
    public var id: String { "\(proto)|\(externalPort)|\(remoteHost ?? "")" }
    /// Only this remote host may use the mapping; nil or empty = anyone on the internet.
    public var remoteHost: String?
    public var externalPort: Int
    /// "TCP" or "UDP".
    public var proto: String
    public var internalPort: Int?
    /// LAN address the router forwards to.
    public var internalClient: String?
    public var enabled: Bool?
    /// Free text set by the app that created it (e.g. "Plex Media Server", "NAT-PMP 51413 tcp"): usually the best clue
    /// to which app opened it.
    public var description: String?
    /// Seconds left; 0 means permanent (until removed or the router restarts).
    public var leaseSeconds: Int?

    public init(remoteHost: String? = nil, externalPort: Int, proto: String, internalPort: Int?, internalClient: String?,
                enabled: Bool?, description: String?, leaseSeconds: Int?) {
        self.remoteHost = remoteHost; self.externalPort = externalPort; self.proto = proto; self.internalPort = internalPort
        self.internalClient = internalClient; self.enabled = enabled; self.description = description; self.leaseSeconds = leaseSeconds
    }
}

/// What one SOAP call returned.
public enum SOAPResult: Hashable, Sendable {
    /// The response's out-arguments by element name ("NewExternalPort" → "8080").
    case values([String: String])
    /// A UPnPError fault: code and description. For GetGenericPortMappingEntry, 713 (SpecifiedArrayIndexInvalid) marks
    /// the end of the list; some routers send 714 (NoSuchEntryInArray) or 402 (Invalid Args) instead.
    case fault(code: Int?, description: String?)
}

public enum IGD {
    /// Service types that carry port mappings, in preference order.
    public static func isWANConnection(_ serviceType: String) -> Bool {
        let t = serviceType.lowercased()
        return t.contains(":service:wanipconnection:") || t.contains(":service:wanpppconnection:")
    }

    /// A SOAP 1.1 request envelope for `action` on `serviceType`. Argument values are XML-escaped.
    public static func envelope(action: String, serviceType: String, args: [(String, String)] = []) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let a = args.map { "<\($0.0)>\(esc($0.1))</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\"?>\r\n<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " +
            "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(esc(serviceType))\">" +
            a + "</u:\(action)></s:Body></s:Envelope>\r\n"
    }

    /// Parses a SOAP response body: the leaf elements of the `<…Response>` element, or the UPnPError of a fault.
    /// Returns nil for anything that isn't a SOAP envelope.
    public static func parseSOAP(_ data: Data) -> SOAPResult? {
        let p = SOAPParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.shouldResolveExternalEntities = false
        xml.delegate = p
        guard xml.parse(), p.sawEnvelope else { return nil }
        if p.fault { return .fault(code: p.values["errorCode"].flatMap { Int($0) }, description: p.values["errorDescription"] ?? p.values["faultstring"]) }
        return .values(p.values)
    }

    /// Collects leaf text by element name; notes whether a Fault was seen.
    final class SOAPParser: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        var fault = false, sawEnvelope = false
        private var text = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "Envelope" { sawEnvelope = true }
            if name == "Fault" { fault = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if values[name] == nil { values[name] = v }
            text = ""
        }
    }

    /// A port mapping from GetGenericPortMappingEntry's out-arguments, or nil if the essential ones are missing.
    public static func mapping(from v: [String: String]) -> UPnPPortMapping? {
        guard let ext = v["NewExternalPort"].flatMap({ Int($0) }), let proto = v["NewProtocol"], !proto.isEmpty else { return nil }
        func opt(_ k: String) -> String? { v[k].flatMap { $0.isEmpty ? nil : $0 } }
        let enabled = v["NewEnabled"].map { $0 == "1" || $0.lowercased() == "true" }
        return UPnPPortMapping(remoteHost: opt("NewRemoteHost"), externalPort: ext, proto: proto.uppercased(),
                               internalPort: v["NewInternalPort"].flatMap { Int($0) }, internalClient: opt("NewInternalClient"),
                               enabled: enabled, description: opt("NewPortMappingDescription"),
                               leaseSeconds: v["NewLeaseDuration"].flatMap { Int($0) })
    }

    /// Whether a GetGenericPortMappingEntry fault means "no entry at this index" (the normal end of the list).
    public static func isEndOfList(_ code: Int?) -> Bool { code == 713 || code == 714 || code == 402 }
}
