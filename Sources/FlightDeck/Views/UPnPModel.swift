import SwiftUI
import FlightDeckCore

// State behind the UPnP destination: runs `UPnPScan.run()` off the main thread when the page appears and on Refresh,
// and while the page is visible listens passively for NOTIFY announcements, folding new devices (and departures) into
// the last scan. Nothing runs while the page is closed. In demo mode it never touches the network and shows
// `Demo.upnpScan()` instead.

@MainActor
final class UPnPModel: ObservableObject {
    @Published private(set) var scan: UPnPScan?
    @Published private(set) var scanning = false
    /// Announcements heard since the page appeared (for the header), and why passive listening isn't running, if not.
    @Published private(set) var heard = 0
    @Published private(set) var listenError: String?
    @Published var selection: String?   // UPnPHostGroup.id (an IP)

    private var listener: SSDPListener?
    private var pending: [(message: SSDPMessage, from: String)] = []
    private var mergeScheduled = false

    init(preview: UPnPScan? = nil) { scan = preview }

    func refresh() {
        if Demo.isEnabled { scan = Demo.upnpScan(); return }
        guard !scanning else { return }
        scanning = true
        Task.detached {
            let s = UPnPScan.run()
            await MainActor.run { self.scan = s; self.scanning = false }
        }
    }

    func appear() {
        refresh()
        guard !Demo.isEnabled, listener == nil else { return }
        let l = SSDPListener { [weak self] m, from in MainActor.assumeIsolated { self?.heard(m, from: from) } }
        listenError = l.error
        listener = l
    }

    func disappear() { listener?.stop(); listener = nil }

    /// Most NOTIFYs are periodic re-announcements of devices already listed; only new LOCATIONs and byebyes cause
    /// work. Those are batched for a second, since a device usually sends a burst of them.
    private func heard(_ m: SSDPMessage, from: String) {
        heard += 1
        guard let scan, !scanning else { return }
        let isNew = m.location.map { loc in !scan.devices.contains { $0.location == loc } } ?? false
        guard isNew || m.nts?.lowercased() == "ssdp:byebye" else { return }
        pending.append((m, from))
        guard !mergeScheduled else { return }
        mergeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let base = self.scan else { return }
            let batch = self.pending; self.pending = []; self.mergeScheduled = false
            Task.detached {
                let s = UPnPScan.merging(base, announcements: batch)
                await MainActor.run { if !self.scanning { self.scan = s } }
            }
        }
    }
}

extension Demo {
    /// An invented home network for screenshots: a router with three port mappings (one to this "Demo Mac"), a TV, a
    /// NAS media server, a speaker and a printer. Addresses are private-range and made up; nothing comes from the
    /// real network.
    static func upnpScan() -> UPnPScan {
        func svc(_ t: String, _ path: String) -> UPnPService {
            UPnPService(serviceType: "urn:schemas-upnp-org:service:\(t)", serviceId: nil,
                        controlURL: "http://192.168.1.1:5000/ctl/\(path)", scpdURL: "http://192.168.1.1:5000/\(path).xml")
        }
        func dev(_ type: String, _ name: String, _ maker: String, _ model: String, _ number: String?, _ desc: String?, services: [UPnPService] = [], embedded: [UPnPDevice] = [], page: String? = nil) -> UPnPDevice {
            var d = UPnPDevice(deviceType: "urn:schemas-upnp-org:device:\(type)")
            d.friendlyName = name; d.manufacturer = maker; d.modelName = model; d.modelNumber = number; d.modelDescription = desc
            d.manufacturerURL = "https://example.com/"; d.serialNumber = "DEMO-0000-0000"
            d.udn = "uuid:demo-" + name.lowercased().replacingOccurrences(of: " ", with: "-")
            d.services = services; d.embedded = embedded; d.presentationURL = page
            return d
        }
        let router = dev("InternetGatewayDevice:2", "Demo Router", "Example Networks", "AX-3000", "v2", "Wi-Fi 6 router",
                         services: [svc("Layer3Forwarding:1", "L3F")],
                         embedded: [dev("WANDevice:2", "WAN Device", "Example Networks", "AX-3000", nil, nil,
                                        services: [svc("WANCommonInterfaceConfig:1", "CmnIfCfg")],
                                        embedded: [dev("WANConnectionDevice:2", "WAN Connection Device", "Example Networks", "AX-3000", nil, nil,
                                                       services: [svc("WANIPConnection:2", "IPConn")])])],
                         page: "http://192.168.1.1/")
        let tv = dev("MediaRenderer:1", "Living Room TV", "Example Electronics", "Vista 55", "VX55", "Smart TV",
                     services: [svc("AVTransport:1", "AVT"), svc("RenderingControl:1", "RC"), svc("ConnectionManager:1", "CM")])
        let nas = dev("MediaServer:1", "Family NAS", "Example Storage", "DataBox 4", "DB4", "Network storage with DLNA server",
                      services: [svc("ContentDirectory:1", "CD"), svc("ConnectionManager:1", "CM")], page: "http://192.168.1.20:5000/")
        let speaker = dev("ZonePlayer:1", "Kitchen", "Example Audio", "Play:3", "S3", "Wireless speaker",
                          embedded: [dev("MediaRenderer:1", "Kitchen - Renderer", "Example Audio", "Play:3", nil, nil,
                                         services: [svc("AVTransport:1", "AVT"), svc("RenderingControl:1", "RC")])])
        let printer = dev("Printer:1", "Office Printer", "Example Imaging", "InkJet 7200", "IJ7200", "Colour inkjet",
                          services: [svc("PrintBasic:1", "PB")], page: "http://192.168.1.40/")
        func root(_ ip: String, _ d: UPnPDevice, _ server: String) -> UPnPRootDevice {
            UPnPRootDevice(ip: ip, location: "http://\(ip):5000/desc.xml", uuid: d.udn, server: server, targets: ["upnp:rootdevice"], description: d)
        }
        let devices = [root("192.168.1.1", router, "Linux UPnP/1.1 MiniUPnPd/2.3"), root("192.168.1.31", tv, "Linux UPnP/1.0 DLNADOC/1.50"),
                       root("192.168.1.20", nas, "Linux UPnP/1.0 DemoMediaServer/1.0"), root("192.168.1.32", speaker, "Linux UPnP/1.0 Speaker/70"),
                       root("192.168.1.40", printer, "RTOS UPnP/1.0 InkJet/1.0")]
        let mappings = [
            UPnPPortMapping(externalPort: 51413, proto: "TCP", internalPort: 51413, internalClient: "192.168.1.10", enabled: true, description: "Transmission at 51413", leaseSeconds: 0),
            UPnPPortMapping(externalPort: 32400, proto: "TCP", internalPort: 32400, internalClient: "192.168.1.20", enabled: true, description: "Media Server", leaseSeconds: 0),
            UPnPPortMapping(externalPort: 3074, proto: "UDP", internalPort: 3074, internalClient: "192.168.1.50", enabled: true, description: "Game Console", leaseSeconds: 3540),
        ]
        let gw = UPnPGatewayReport(deviceID: devices[0].id, serviceType: "urn:schemas-upnp-org:service:WANIPConnection:2", externalIP: "203.0.113.42", mappings: mappings)
        var names: [String: String] = [:]
        for d in devices { names[d.ip] = d.description?.friendlyName }
        names["192.168.1.50"] = "game-console.local"; names["192.168.1.10"] = "This Mac"
        return UPnPScan(devices: devices.sorted { $0.category < $1.category }, gateway: gw, hostNames: names, localAddresses: ["192.168.1.10"])
    }
}
