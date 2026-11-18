// Tests for the UPnP destination's parsers: SSDP replies and NOTIFYs, device description XML (embedded devices, URLBase
// and relative URLs), IGD SOAP replies including the end-of-list fault, device classification, and a live SSDP search
// that skips when the network doesn't allow it. Sample data is synthetic, modelled on real routers and players, with
// documentation addresses.
import XCTest
@testable import FlightDeckCore

final class UPnPTests: XCTestCase {
    // MARK: SSDP

    func testSearchResponse() throws {
        let r = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nDATE: Tue, 17 Nov 2026 10:00:00 GMT\r\nEXT:\r\n" +
            "LOCATION: http://192.168.1.1:5000/rootDesc.xml\r\nSERVER: Linux/5.4 UPnP/1.1 MiniUPnPd/2.3.3\r\n" +
            "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n" +
            "USN: uuid:a1b2c3d4-0000-1000-8000-0123456789ab::urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
        let m = try XCTUnwrap(SSDP.parse(r))
        XCTAssertEqual(m.kind, .response)
        XCTAssertEqual(m.location, "http://192.168.1.1:5000/rootDesc.xml")
        XCTAssertEqual(m.searchTarget, "urn:schemas-upnp-org:device:InternetGatewayDevice:1")
        XCTAssertEqual(m.server, "Linux/5.4 UPnP/1.1 MiniUPnPd/2.3.3")
        XCTAssertEqual(m.uuid, "a1b2c3d4-0000-1000-8000-0123456789ab")
        XCTAssertEqual(m.headers["EXT"], "")
    }

    /// NOTIFY with lower-case header names and bare LF line endings, as some devices send.
    func testNotify() throws {
        let n = "NOTIFY * HTTP/1.1\nHost: 239.255.255.250:1900\nnt: urn:schemas-upnp-org:device:ZonePlayer:1\nNTS: ssdp:alive\n" +
            "Location: http://192.168.1.30:1400/xml/device_description.xml\nusn: uuid:RINCON_000000000001400::urn:schemas-upnp-org:device:ZonePlayer:1\n\n"
        let m = try XCTUnwrap(SSDP.parse(n))
        XCTAssertEqual(m.kind, .notify)
        XCTAssertEqual(m.nts, "ssdp:alive")
        XCTAssertEqual(m.searchTarget, "urn:schemas-upnp-org:device:ZonePlayer:1")   // NT stands in for ST
        XCTAssertEqual(m.uuid, "RINCON_000000000001400")
        XCTAssertEqual(SSDP.parse(SSDP.search(target: "ssdp:all"))?.kind, .search)
        XCTAssertNil(SSDP.parse("GET / HTTP/1.1\r\n\r\n"))
        XCTAssertNil(SSDP.parse("HTTP/1.1 404 Not Found\r\n\r\n"))
    }

    func testGroupingAndByebye() {
        func msg(_ s: String) -> SSDPMessage { SSDP.parse(s)! }
        let a1 = msg("HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.1/d.xml\r\nST: upnp:rootdevice\r\nUSN: uuid:gw::upnp:rootdevice\r\n\r\n")
        let a2 = msg("HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.1/d.xml\r\nST: urn:x:service:WANIPConnection:1\r\nUSN: uuid:gw::urn:x\r\nSERVER: R/1\r\n\r\n")
        let b = msg("NOTIFY * HTTP/1.1\r\nNT: upnp:rootdevice\r\nNTS: ssdp:alive\r\nLOCATION: http://192.168.1.9/d.xml\r\nUSN: uuid:tv::upnp:rootdevice\r\n\r\n")
        let bye = msg("NOTIFY * HTTP/1.1\r\nNT: upnp:rootdevice\r\nNTS: ssdp:byebye\r\nUSN: uuid:tv::upnp:rootdevice\r\n\r\n")
        let g = UPnPScan.group([(a1, "192.168.1.1"), (a2, "192.168.1.1"), (b, "192.168.1.9")])
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g[0].targets.count, 2); XCTAssertEqual(g[0].server, "R/1")
        XCTAssertEqual(UPnPScan.group([(b, "192.168.1.9"), (bye, "192.168.1.9")]).count, 0)
    }

    // MARK: Device descriptions

    /// A router description: UPnP 1.0 with URLBase, relative URLs with and without a leading slash, a namespace
    /// prefix, embedded WANDevice → WANConnectionDevice.
    static let routerXML = """
    <?xml version="1.0"?>
    <r:root xmlns:r="urn:schemas-upnp-org:device-1-0">
      <r:specVersion><r:major>1</r:major><r:minor>0</r:minor></r:specVersion>
      <r:URLBase>http://192.168.1.1:5000/</r:URLBase>
      <r:device>
        <r:deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</r:deviceType>
        <r:friendlyName>Example Router</r:friendlyName>
        <r:manufacturer>Example Networks</r:manufacturer>
        <r:manufacturerURL>https://example.com/</r:manufacturerURL>
        <r:modelName>XR-500</r:modelName><r:modelNumber>v2</r:modelNumber>
        <r:serialNumber>SN0001</r:serialNumber>
        <r:UDN>uuid:gw-1</r:UDN>
        <r:presentationURL>/</r:presentationURL>
        <r:iconList>
          <r:icon><r:mimetype>image/png</r:mimetype><r:width>120</r:width><r:height>120</r:height><r:depth>24</r:depth><r:url>/icons/big.png</r:url></r:icon>
          <r:icon><r:mimetype>image/png</r:mimetype><r:width>48</r:width><r:height>48</r:height><r:depth>24</r:depth><r:url>icons/48.png</r:url></r:icon>
        </r:iconList>
        <r:serviceList><r:service>
          <r:serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</r:serviceType>
          <r:serviceId>urn:upnp-org:serviceId:L3Forwarding1</r:serviceId>
          <r:controlURL>/ctl/L3F</r:controlURL><r:eventSubURL>/evt/L3F</r:eventSubURL><r:SCPDURL>/L3F.xml</r:SCPDURL>
        </r:service></r:serviceList>
        <r:deviceList><r:device>
          <r:deviceType>urn:schemas-upnp-org:device:WANDevice:1</r:deviceType>
          <r:friendlyName>WANDevice</r:friendlyName>
          <r:UDN>uuid:gw-2</r:UDN>
          <r:deviceList><r:device>
            <r:deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:1</r:deviceType>
            <r:friendlyName>WANConnectionDevice</r:friendlyName>
            <r:UDN>uuid:gw-3</r:UDN>
            <r:serviceList><r:service>
              <r:serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</r:serviceType>
              <r:serviceId>urn:upnp-org:serviceId:WANIPConn1</r:serviceId>
              <r:controlURL>ctl/IPConn</r:controlURL><r:eventSubURL>/evt/IPConn</r:eventSubURL><r:SCPDURL>/WANIPCn.xml</r:SCPDURL>
            </r:service></r:serviceList>
          </r:device></r:deviceList>
        </r:device></r:deviceList>
      </r:device>
    </r:root>
    """

    func testRouterDescription() throws {
        let d = try XCTUnwrap(UPnP.parseDescription(Data(Self.routerXML.utf8), location: "http://192.168.1.1:5000/rootDesc.xml"))
        let r = d.root
        XCTAssertEqual(d.baseURL, "http://192.168.1.1:5000/")
        XCTAssertEqual(r.friendlyName, "Example Router"); XCTAssertEqual(r.manufacturer, "Example Networks")
        XCTAssertEqual(r.modelName, "XR-500"); XCTAssertEqual(r.modelNumber, "v2"); XCTAssertEqual(r.serialNumber, "SN0001")
        XCTAssertEqual(r.udn, "uuid:gw-1"); XCTAssertEqual(r.shortType, "InternetGatewayDevice:1")
        XCTAssertEqual(r.presentationURL, "http://192.168.1.1:5000/")
        XCTAssertEqual(r.icons.count, 2)
        XCTAssertEqual(r.bestIcon?.url, "http://192.168.1.1:5000/icons/48.png")
        // The root's own fields must not be overwritten by the embedded devices' friendlyName/UDN.
        XCTAssertEqual(r.services.map(\.shortName), ["Layer3Forwarding:1"])
        XCTAssertEqual(r.embedded.count, 1); XCTAssertEqual(r.embedded[0].embedded.count, 1)
        XCTAssertEqual(r.allDevices.count, 3)
        let wan = try XCTUnwrap(r.allServices.first { IGD.isWANConnection($0.serviceType) })
        XCTAssertEqual(wan.controlURL, "http://192.168.1.1:5000/ctl/IPConn")
        XCTAssertEqual(wan.scpdURL, "http://192.168.1.1:5000/WANIPCn.xml")
        XCTAssertEqual(UPnPCategory.of(r), .gateway)
    }

    /// No URLBase (UPnP 1.1): relative URLs resolve against the location, including relative to its directory.
    func testRelativeToLocation() throws {
        let xml = """
        <root xmlns="urn:schemas-upnp-org:device-1-0"><device>
          <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType><friendlyName>NAS</friendlyName>
          <presentationURL>http://192.168.1.20:5000/</presentationURL>
          <serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
            <controlURL>ContentDir/control</controlURL><SCPDURL>/cd.xml</SCPDURL></service></serviceList>
        </device></root>
        """
        let d = try XCTUnwrap(UPnP.parseDescription(Data(xml.utf8), location: "http://192.168.1.20:50001/desc/device.xml"))
        XCTAssertEqual(d.root.services[0].controlURL, "http://192.168.1.20:50001/desc/ContentDir/control")
        XCTAssertEqual(d.root.services[0].scpdURL, "http://192.168.1.20:50001/cd.xml")
        XCTAssertEqual(d.root.presentationURL, "http://192.168.1.20:5000/")   // absolute: unchanged
        XCTAssertNil(d.root.serialNumber)   // not reported → nil, not ""
        XCTAssertEqual(UPnPCategory.of(d.root), .mediaServer)
        XCTAssertNil(UPnP.parseDescription(Data("<root><notdevice/></root>".utf8), location: nil))
        XCTAssertNil(UPnP.parseDescription(Data("not xml <".utf8), location: nil))
    }

    // MARK: Classification

    func testClassification() {
        func dev(_ type: String, services: [String] = [], embedded: [UPnPDevice] = []) -> UPnPDevice {
            var d = UPnPDevice(deviceType: "urn:schemas-upnp-org:device:\(type)")
            d.services = services.map { UPnPService(serviceType: "urn:schemas-upnp-org:service:\($0)") }
            d.embedded = embedded
            return d
        }
        // Sonos-style: ZonePlayer embedding a MediaServer and a MediaRenderer is a renderer.
        XCTAssertEqual(UPnPCategory.of(dev("ZonePlayer:1", embedded: [dev("MediaServer:1"), dev("MediaRenderer:1")])), .mediaRenderer)
        // A TV that only lists services.
        XCTAssertEqual(UPnPCategory.of(dev("Basic:1", services: ["AVTransport:1", "RenderingControl:1"])), .mediaRenderer)
        // A router that also serves media from a USB disk stays a gateway.
        XCTAssertEqual(UPnPCategory.of(dev("InternetGatewayDevice:2", embedded: [dev("MediaServer:1")])), .gateway)
        XCTAssertEqual(UPnPCategory.of(dev("Printer:1")), .printer)
        XCTAssertEqual(UPnPCategory.of(dev("Basic:1", services: ["PrintBasic:1"])), .printer)
        XCTAssertEqual(UPnPCategory.of(dev("Basic:1")), .other)
        XCTAssertEqual(UPnP.shortType("urn:dial-multiscreen-org:service:dial:1"), "dial:1")
        XCTAssertEqual(UPnP.shortType("ssdp:all"), "ssdp:all")
    }

    // MARK: SOAP

    func testPortMappingEntry() throws {
        let xml = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>
        <u:GetGenericPortMappingEntryResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">
        <NewRemoteHost></NewRemoteHost><NewExternalPort>32400</NewExternalPort><NewProtocol>TCP</NewProtocol>
        <NewInternalPort>32400</NewInternalPort><NewInternalClient>192.168.1.20</NewInternalClient><NewEnabled>1</NewEnabled>
        <NewPortMappingDescription>Plex Media Server</NewPortMappingDescription><NewLeaseDuration>0</NewLeaseDuration>
        </u:GetGenericPortMappingEntryResponse></s:Body></s:Envelope>
        """
        guard case .values(let v) = try XCTUnwrap(IGD.parseSOAP(Data(xml.utf8))) else { return XCTFail("expected values") }
        let m = try XCTUnwrap(IGD.mapping(from: v))
        XCTAssertEqual(m.externalPort, 32400); XCTAssertEqual(m.proto, "TCP"); XCTAssertEqual(m.internalPort, 32400)
        XCTAssertEqual(m.internalClient, "192.168.1.20"); XCTAssertEqual(m.enabled, true)
        XCTAssertEqual(m.description, "Plex Media Server"); XCTAssertEqual(m.leaseSeconds, 0)
        XCTAssertNil(m.remoteHost)   // empty = any remote host
        XCTAssertNil(IGD.mapping(from: ["NewProtocol": "UDP"]))   // no external port: not a mapping
    }

    func testEndOfListFault() throws {
        let xml = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>
        <faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
        <detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>713</errorCode>
        <errorDescription>SpecifiedArrayIndexInvalid</errorDescription></UPnPError></detail>
        </s:Fault></s:Body></s:Envelope>
        """
        let r = try XCTUnwrap(IGD.parseSOAP(Data(xml.utf8)))
        XCTAssertEqual(r, .fault(code: 713, description: "SpecifiedArrayIndexInvalid"))
        XCTAssertTrue(IGD.isEndOfList(713)); XCTAssertFalse(IGD.isEndOfList(501)); XCTAssertFalse(IGD.isEndOfList(nil))
        XCTAssertNil(IGD.parseSOAP(Data("<html>nope</html>".utf8)))
    }

    func testExternalIPAndEnvelope() throws {
        let xml = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:GetExternalIPAddressResponse xmlns:u=\"urn:x\">" +
            "<NewExternalIPAddress>203.0.113.7</NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body></s:Envelope>"
        XCTAssertEqual(IGD.parseSOAP(Data(xml.utf8)), .values(["NewExternalIPAddress": "203.0.113.7", "GetExternalIPAddressResponse": "", "Body": "", "Envelope": ""]))
        let env = IGD.envelope(action: "GetGenericPortMappingEntry", serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1", args: [("NewPortMappingIndex", "3")])
        XCTAssertTrue(env.contains("<u:GetGenericPortMappingEntry xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\"><NewPortMappingIndex>3</NewPortMappingIndex>"))
    }

    // MARK: Integration model

    func testHostsModel() {
        var d = UPnPDevice(deviceType: "urn:schemas-upnp-org:device:MediaRenderer:1")
        d.friendlyName = "Living Room"; d.manufacturer = "Acme"; d.modelName = "Play"; d.modelNumber = "5"
        d.services = [UPnPService(serviceType: "urn:schemas-upnp-org:service:AVTransport:1")]
        let scan = UPnPScan(devices: [UPnPRootDevice(ip: "192.168.1.30", location: "http://192.168.1.30/d.xml", uuid: "x", server: nil, targets: [], description: d),
                                      UPnPRootDevice(ip: "192.168.1.40", location: "http://192.168.1.40/d.xml", uuid: "y", server: nil, targets: [], descriptionError: "timed out")],
                            gateway: nil, hostNames: [:], localAddresses: [])
        let h = scan.hosts
        XCTAssertEqual(h[0].model, "Play 5"); XCTAssertEqual(h[0].category, .mediaRenderer); XCTAssertEqual(h[0].services.count, 1)
        XCTAssertNil(h[1].friendlyName); XCTAssertNil(h[1].model); XCTAssertEqual(h[1].category, .other)
    }

    /// A TV with a DIAL root device and a MediaRenderer root device at one IP is one host, classed by the renderer.
    func testByHost() {
        var dial = UPnPDevice(deviceType: "urn:dial-multiscreen-org:device:dial:1"); dial.friendlyName = "TV"
        var mr = UPnPDevice(deviceType: "urn:schemas-upnp-org:device:MediaRenderer:1"); mr.friendlyName = "Bedroom TV"
        let scan = UPnPScan(devices: [UPnPRootDevice(ip: "192.168.1.9", location: "http://192.168.1.9:1/a", uuid: nil, server: nil, targets: [], description: dial),
                                      UPnPRootDevice(ip: "192.168.1.9", location: "http://192.168.1.9:2/b", uuid: nil, server: nil, targets: [], description: mr),
                                      UPnPRootDevice(ip: "192.168.1.5", location: "http://192.168.1.5/c", uuid: nil, server: "Box/1", targets: [])],
                            gateway: nil, hostNames: [:], localAddresses: [])
        let g = scan.byHost
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g[0].ip, "192.168.1.9"); XCTAssertEqual(g[0].category, .mediaRenderer); XCTAssertEqual(g[0].displayName, "Bedroom TV")
        XCTAssertEqual(g[1].displayName, "192.168.1.5")   // no description: falls back to the IP
    }

    // MARK: Live

    /// A real search on this network. Skips where multicast can't be sent (CI VMs, Local Network access denied) or
    /// nothing answers; otherwise checks that every reply parsed into a device with an address.
    func testLiveSearch() throws {
        let (datagrams, error) = SSDPSocket.search(listen: 2)
        if let error { throw XCTSkip("SSDP unavailable here: \(error)") }
        if datagrams.isEmpty { throw XCTSkip("no UPnP devices answered on this network") }
        let devices = UPnPScan.group(datagrams.compactMap { d in SSDP.parse(d.text).map { ($0, d.from) } })
        XCTAssertFalse(devices.isEmpty)
        XCTAssertTrue(devices.allSatisfy { !$0.ip.isEmpty && !$0.location.isEmpty })
    }
}
