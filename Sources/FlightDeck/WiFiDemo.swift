// Invented Wi-Fi data for demo mode and the demo render: a made-up neighbourhood of 15 networks across 2.4, 5 and
// 6 GHz, and half an hour of a made-up link that roams between two access points and drops to 2.4 GHz for a while.
// No scan is run and nothing comes from this Mac. SSIDs are invented, and every BSSID is a locally administered
// address (second hex digit 2), the kind no manufacturer is assigned, so none can be a real access point's; their
// vendor therefore reads as "private address", as it would for a real AP using such addresses.
import Foundation
import FlightDeckCore

enum WiFiDemo {
    static let ownSSID = "Demo Home"
    /// The two invented access points of "Demo Home": the office one (5 GHz 36) and the kitchen one (5 GHz 149, with
    /// its 2.4 GHz radio on channel 6).
    static let officeAP = "02:de:00:00:00:10", kitchenAP = "02:de:00:00:00:20", kitchen24 = "02:de:00:00:00:21"

    static func scan(at time: Date) -> WiFiScanResult {
        // (ssid, bssid suffix, rssi, band, channel, width, security, phy)
        let rows: [(String?, String, Int, WiFiBand, Int, Int, String, String)] = [
            (ownSSID, "20", -54, .ghz5, 149, 80, "WPA3", "802.11ax (Wi-Fi 6)"),
            (ownSSID, "10", -71, .ghz5, 36, 80, "WPA3", "802.11ax (Wi-Fi 6)"),
            (ownSSID, "21", -49, .ghz2, 6, 20, "WPA2/WPA3", "802.11ax (Wi-Fi 6)"),
            ("Maple Street 5G", "31", -62, .ghz5, 157, 80, "WPA2", "802.11ac (Wi-Fi 5)"),
            ("Maple Street", "30", -60, .ghz2, 6, 20, "WPA2", "802.11n (Wi-Fi 4)"),
            ("Bluebird", "41", -66, .ghz5, 149, 40, "WPA2", "802.11ac (Wi-Fi 5)"),
            ("Bluebird-2G", "40", -68, .ghz2, 1, 20, "WPA2", "802.11n (Wi-Fi 4)"),
            ("Corner Café Guest", "50", -74, .ghz2, 11, 20, "Open", "802.11n (Wi-Fi 4)"),
            ("Larkspur", "61", -69, .ghz5, 44, 80, "WPA3", "802.11ax (Wi-Fi 6)"),
            ("Larkspur 6E", "62", -73, .ghz6, 37, 160, "WPA3", "802.11ax (Wi-Fi 6)"),
            ("Orbit-7", "71", -77, .ghz6, 5, 320, "WPA3", "802.11be (Wi-Fi 7)"),
            ("Printer-Direct", "80", -63, .ghz2, 6, 20, "WPA2", "802.11n (Wi-Fi 4)"),
            (nil, "90", -81, .ghz5, 100, 80, "WPA2", "802.11ac (Wi-Fi 5)"),
            ("Harbor Lights", "a1", -79, .ghz5, 161, 80, "WPA2", "802.11ac (Wi-Fi 5)"),
            ("Harbor Lights", "a0", -72, .ghz2, 3, 40, "WPA2", "802.11n (Wi-Fi 4)"),
        ]
        let nets = rows.sorted { $0.2 > $1.2 }.enumerated().map { k, r in
            WiFiNetwork(id: k, ssid: r.0, bssid: "02:de:00:00:00:" + r.1, rssi: r.2, noise: r.3 == .ghz2 ? -90 : -95, band: r.3,
                        channel: r.4, widthMHz: r.5, security: r.6, phy: r.7, countryCode: "US")
        }
        return WiFiScanResult(time: time.addingTimeInterval(-40), networks: nets, identifiersHidden: false, ownBSSID: kitchenAP,
                              ownChannel: 149, ownBand: .ghz5, ownSSID: ownSSID)
    }

    /// 30 minutes, one reading every 5 s: steady in the office, a walk to the kitchen with a roam, ten minutes on
    /// 2.4 GHz in the garden, and back to the kitchen's 5 GHz radio.
    static func history(until end: Date) -> [WiFiLinkPoint] {
        let n = 360
        return (0..<n).map { i in
            let t = Double(i)
            let wiggle = Int((sin(t * 0.7) * 2 + sin(t * 0.13) * 1.5).rounded())
            let time = end.addingTimeInterval(Double(i - n + 1) * 5)
            let (rssi, ap, band, ch, rate): (Int, String, WiFiBand, Int, Double)
            switch i {
            case ..<100: (rssi, ap, band, ch, rate) = (-52, officeAP, .ghz5, 36, 1080)
            // Walking away from the office AP: the signal and rate fall until the Mac roams.
            case ..<130: let d = (i - 100) * 2 / 3; (rssi, ap, band, ch, rate) = (-52 - d, officeAP, .ghz5, 36, max(240, 1080 - Double(d) * 40))
            case ..<200: (rssi, ap, band, ch, rate) = (-57, kitchenAP, .ghz5, 149, 960)
            case ..<280: (rssi, ap, band, ch, rate) = (-64, kitchen24, .ghz2, 6, 172)
            default: (rssi, ap, band, ch, rate) = (-55, kitchenAP, .ghz5, 149, 1020)
            }
            return WiFiLinkPoint(time: time, rssi: rssi + wiggle, noise: (band == .ghz2 ? -90 : -94) + (i % 3 == 0 ? 1 : 0),
                                 txRate: max(6, rate + Double(wiggle) * 20), channel: ch, band: band, widthMHz: band == .ghz2 ? 20 : 80, bssid: ap)
        }
    }

}
