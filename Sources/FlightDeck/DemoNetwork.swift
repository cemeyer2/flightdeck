// Demo mode for the Network view: an invented home network, so README screenshots never show the real one. Nothing
// here reads this Mac: interfaces, neighbour entries, Bonjour services, names, the access point and traceroute hops
// are all made up and fed through the same merge/classify/topology code the live view uses. MAC prefixes are real
// vendor OUIs (so the manufacturer column has something to show) with invented low octets; addresses are in
// 192.168.50.0/24 and the internet hops use documentation ranges (RFC 5737).
import Foundation
import FlightDeckCore

extension Demo {
    static func networkSurvey(now: Date = Date()) -> NetworkSurvey {
        let net = "192.168.50."
        let wifi = NetInterface(name: "en0", displayName: "Wi-Fi", kind: .wifi, mac: "02:5e:a1:00:00:01",
                                ipv4: [IPv4Net(address: net + "23", prefix: 24)], ipv6: ["fe80::1c:5ea1:0:1"])
        // (last octet, MAC) of everything in the invented ARP table.
        let arp: [(Int, String)] = [
            (1, "00:09:5b:4d:10:01"),    // Netgear router
            (10, "00:11:32:7a:22:10"),   // Synology NAS
            (12, "00:1b:a9:3c:51:12"),   // Brother printer
            (15, "00:0e:58:aa:01:15"),   // Sonos speaker
            (16, "00:0e:58:aa:02:16"),   // second Sonos
            (20, "00:0d:4b:61:77:20"),   // Roku TV
            (31, "8a:41:c2:19:6e:31"),   // phone, private address
            (32, "d6:0f:3a:88:12:32"),   // phone, private address
            (33, "00:05:02:6b:4e:33"),   // iPad
            (40, "00:17:88:42:9a:40"),   // Hue bridge
            (41, "44:61:32:0c:1d:41"),   // ecobee thermostat
            (42, "00:4b:12:5f:33:42"),   // Espressif smart plug
            (43, "00:4b:12:5f:34:43"),   // Espressif smart plug
            (44, "00:b4:63:21:0e:44"),   // Ring doorbell
            (50, "00:09:bf:3e:70:50"),   // Nintendo console
            (61, "00:00:f0:12:ab:61"),   // Samsung, nothing advertised
        ]
        let neighbors = arp.map { NeighborEntry(ip: net + "\($0.0)", mac: $0.1, interface: "en0") }
            + [NeighborEntry(ip: "fe80::209:5bff:fe4d:1001", mac: "00:09:5b:4d:10:01", interface: "en0", isIPv6: true, isRouter: true)]
        func svc(_ name: String, _ type: String, _ host: String, _ last: Int, _ txt: [String: String] = [:]) -> BonjourService {
            BonjourService(name: name, type: type, interface: "en0", host: host + ".local.", addresses: [net + "\(last)"], txt: txt)
        }
        let services = [
            svc("Family Files", "_smb._tcp", "FamilyFiles", 10), svc("Family Files", "_device-info._tcp", "FamilyFiles", 10, ["model": "DiskStation DS920+"]),
            svc("Office Printer", "_ipp._tcp", "OfficePrinter", 12, ["ty": "Brother HL-L2350DW"]),
            svc("Living Room", "_sonos._tcp", "Sonos-Living-Room", 15), svc("Living Room", "_spotify-connect._tcp", "Sonos-Living-Room", 15),
            svc("Kitchen", "_sonos._tcp", "Sonos-Kitchen", 16),
            svc("Den TV", "_airplay._tcp", "Den-TV", 20, ["model": "Roku Ultra"]),
            svc("Alex's iPhone", "_companion-link._tcp", "Alexs-iPhone", 31), svc("Alex's iPhone", "_device-info._tcp", "Alexs-iPhone", 31, ["model": "iPhone16,1"]),
            svc("Sam's iPad", "_companion-link._tcp", "Sams-iPad", 33), svc("Sam's iPad", "_device-info._tcp", "Sams-iPad", 33, ["model": "iPad13,18"]),
            svc("Hue Bridge", "_hue._tcp", "Philips-hue", 40), svc("Hue Bridge", "_hap._tcp", "Philips-hue", 40, ["md": "BSB002"]),
            svc("Hallway Thermostat", "_hap._tcp", "ecobee-Hallway", 41),
            svc("Front Door", "_hap._tcp", "Ring-Front-Door", 44),
        ]
        let reverse = [net + "1": "router.home", net + "32": "Galaxy-S24", net + "42": "plug-lamp", net + "43": "plug-heater"]
        let route = DefaultRoute(gateway: net + "1", interface: "en0")
        // First-seen times spread over the last few hours, so the column isn't uniform.
        var seen: [String: (first: Date, last: Date)] = [:]
        for (i, a) in arp.enumerated() { let t = now.addingTimeInterval(-Double(600 + i * 1_337)); seen["mac:" + a.1] = (t, t) }
        let devices = NetworkInventory.merge(interfaces: [wifi], neighbors: neighbors, services: services, reverseDNS: reverse,
                                             route: route, seen: seen, now: now)
        let ap = AccessPoint(ssid: "Demo Home", bssid: "00:09:5b:4d:10:05", channel: "149 · 5 GHz · 80 MHz", rssi: -54)
        let hops = [TraceHop(number: 1, ip: net + "1", ms: 2.1), TraceHop(number: 2, ip: "198.51.100.1", ms: 8.4),
                    TraceHop(number: 3, ip: nil, ms: nil), TraceHop(number: 4, ip: "203.0.113.9", ms: 14.9),
                    TraceHop(number: 5, ip: "192.0.2.53", ms: 17.2)]
        let topo = NetTopology.build(interfaces: [wifi], devices: devices, route: route, wifi: ap, hops: hops)
        return NetworkSurvey(time: now, interfaces: [wifi], devices: devices, topology: topo, route: route,
                             dns: [net + "1"], accessPoint: ap, notes: [])
    }
}
