import Foundation
import CoreWLAN
// Nearby Wi-Fi networks from one CoreWLAN scan. A scan makes the Wi-Fi radio leave its channel briefly to listen on
// every other one, which can stall the connection for a second or two, so nothing here runs on its own: the Wi-Fi page
// scans when the user presses Scan or, if they turn it on, on a timer while the page is visible.
//
// Privacy: SSIDs and BSSIDs reveal where the Mac is (they can be looked up in public Wi-Fi location databases), so
// macOS only gives them to apps with Location Services permission. Scans are kept in memory only, never written to
// disk, and the MCP tool leaves BSSIDs out unless permission was granted.

/// One network (one BSSID: one radio of one access point) heard in a scan.
public struct WiFiNetwork: Codable, Sendable, Hashable, Identifiable {
    /// Position in the scan; stable for one scan only (BSSIDs can't be the id because they may be hidden).
    public var id: Int
    /// nil when hidden by macOS (no Location permission) or when the network doesn't broadcast its name.
    public var ssid: String?
    /// Lowercase, colon-separated; nil without Location permission.
    public var bssid: String?
    public var rssi: Int
    /// dBm; nil when the driver reported 0 (not measured).
    public var noise: Int?
    public var band: WiFiBand?
    /// Primary 20 MHz channel.
    public var channel: Int?
    /// From the beacon's IEs when present (can be 320), otherwise CoreWLAN's width (max 160); nil if unknown.
    public var widthMHz: Int?
    /// Centre channel of the occupied block, from the beacon; nil means "derive it from the primary and width".
    public var centerChannel: Int?
    /// Secondary channel direction for 40 MHz on 2.4 GHz, from the beacon.
    public var secondaryAbove: Bool?
    public var security: String?
    /// Newest standard the network advertises ("802.11ax (Wi-Fi 6)").
    public var phy: String?
    public var countryCode: String?

    public init(id: Int, ssid: String? = nil, bssid: String? = nil, rssi: Int, noise: Int? = nil, band: WiFiBand?, channel: Int?,
                widthMHz: Int?, centerChannel: Int? = nil, secondaryAbove: Bool? = nil, security: String? = nil, phy: String? = nil,
                countryCode: String? = nil) {
        self.id = id; self.ssid = ssid; self.bssid = bssid; self.rssi = rssi; self.noise = noise; self.band = band; self.channel = channel
        self.widthMHz = widthMHz; self.centerChannel = centerChannel; self.secondaryAbove = secondaryAbove; self.security = security
        self.phy = phy; self.countryCode = countryCode
    }

    /// Vendor of the access point from the BSSID's OUI. Many APs use locally administered BSSIDs for their extra SSIDs,
    /// which have no vendor (`OUI.lookup` says so rather than guessing).
    public var vendor: Vendor { OUI.lookup(bssid) }

    /// The spectrum this network occupies, in MHz, accounting for its width.
    public var span: ClosedRange<Double>? {
        guard let band, let channel else { return nil }
        let w = widthMHz ?? 20
        let c = centerChannel ?? WiFiChannels.centerChannel(band: band, primary: channel, width: w, secondaryAbove: secondaryAbove)
        return WiFiChannels.span(band: band, primary: channel, width: w, center: c)
    }
}

/// The result of one scan.
public struct WiFiScanResult: Codable, Sendable, Hashable {
    public var time: Date
    public var networks: [WiFiNetwork]
    /// True when every network came back without an SSID and BSSID: macOS is withholding them because FlightDeck
    /// doesn't have Location Services permission. (Hidden-SSID networks alone would still have BSSIDs.)
    public var identifiersHidden: Bool
    /// The BSSID this Mac is associated with, when known (also needs Location permission).
    public var ownBSSID: String?
    /// This Mac's current primary channel and band at scan time, for matching "our" network when BSSIDs are hidden.
    public var ownChannel: Int?
    public var ownBand: WiFiBand?
    public var ownSSID: String?
    public init(time: Date, networks: [WiFiNetwork], identifiersHidden: Bool, ownBSSID: String? = nil, ownChannel: Int? = nil,
                ownBand: WiFiBand? = nil, ownSSID: String? = nil) {
        self.time = time; self.networks = networks; self.identifiersHidden = identifiersHidden; self.ownBSSID = ownBSSID
        self.ownChannel = ownChannel; self.ownBand = ownBand; self.ownSSID = ownSSID
    }

    /// Whether a network is this Mac's own network: the associated BSSID, or another radio/AP broadcasting the same
    /// SSID (a mesh or a dual-band router). Without identifiers, nothing can be told apart, so nothing counts as ours.
    public func isOwn(_ n: WiFiNetwork) -> Bool {
        if let b = ownBSSID, n.bssid == b { return true }
        if let s = ownSSID, n.ssid == s { return true }
        return false
    }

    /// The scan entry for the associated BSSID, if identifiers are visible.
    public var own: WiFiNetwork? { networks.first { n in ownBSSID != nil && n.bssid == ownBSSID } }
}

public enum WiFiScanner {
    public enum ScanError: Error, CustomStringConvertible {
        case noInterface, poweredOff, failed(String)
        public var description: String {
            switch self {
            case .noInterface: "This Mac has no Wi-Fi interface."
            case .poweredOff: "Wi-Fi is turned off."
            case .failed(let s): "The scan failed: \(s)"
            }
        }
    }

    /// Runs one active scan (blocks for a few seconds; call off the main thread). Includes networks that hide their
    /// SSID, which still occupy the channel.
    public static func scan() -> Result<WiFiScanResult, ScanError> {
        guard let i = CWWiFiClient.shared().interface() else { return .failure(.noInterface) }
        guard i.powerOn() else { return .failure(.poweredOff) }
        let found: Set<CWNetwork>
        do { found = try i.scanForNetworks(withSSID: nil, includeHidden: true) } catch { return .failure(.failed(error.localizedDescription)) }
        // Strongest first, so the list reads top-down and ids follow that order.
        let nets = found.sorted { $0.rssiValue > $1.rssiValue }.enumerated().map { k, n in network(n, id: k) }
        let hidden = !nets.isEmpty && nets.allSatisfy { $0.ssid == nil && $0.bssid == nil }
        let ch = i.wlanChannel()
        return .success(WiFiScanResult(time: Date(), networks: nets, identifiersHidden: hidden, ownBSSID: i.bssid().flatMap(MAC.normalize),
                                       ownChannel: ch?.channelNumber, ownBand: ch.flatMap { band($0.channelBand) }, ownSSID: i.ssid()))
    }

    static func band(_ b: CWChannelBand) -> WiFiBand? {
        switch b { case .band2GHz: .ghz2; case .band5GHz: .ghz5; case .band6GHz: .ghz6; default: nil }
    }

    static func width(_ w: CWChannelWidth) -> Int? {
        switch w { case .width20MHz: 20; case .width40MHz: 40; case .width80MHz: 80; case .width160MHz: 160; default: nil }
    }

    static func network(_ n: CWNetwork, id: Int) -> WiFiNetwork {
        let ch = n.wlanChannel
        let beacon = WiFiIE.parse(n.informationElementData, primary: ch?.channelNumber)
        // Empty strings mean "not given" (hidden-SSID networks report ""), so they are stored as nil.
        let ssid = n.ssid.flatMap { $0.isEmpty ? nil : $0 }
        return WiFiNetwork(id: id, ssid: ssid, bssid: n.bssid.flatMap(MAC.normalize), rssi: n.rssiValue,
                           noise: n.noiseMeasurement == 0 ? nil : n.noiseMeasurement, band: ch.flatMap { band($0.channelBand) },
                           channel: ch?.channelNumber, widthMHz: beacon.widthMHz ?? ch.flatMap { width($0.channelWidth) },
                           centerChannel: beacon.centerChannel, secondaryAbove: beacon.secondaryAbove, security: security(n),
                           phy: phy(n, beacon: beacon), countryCode: n.countryCode)
    }

    /// The strongest security the network offers, checked from strongest to weakest.
    static func security(_ n: CWNetwork) -> String? {
        let order: [(CWSecurity, String)] = [
            (.wpa3Enterprise, "WPA3 Enterprise"), (.wpa2Enterprise, "WPA2 Enterprise"), (.enterprise, "Enterprise"),
            (.wpaEnterprise, "WPA Enterprise"), (.wpaEnterpriseMixed, "WPA Enterprise"), (.wpa3Personal, "WPA3"),
            (.wpa3Transition, "WPA2/WPA3"), (.wpa2Personal, "WPA2"), (.personal, "WPA2"), (.wpaPersonalMixed, "WPA/WPA2"),
            (.wpaPersonal, "WPA"), (.OWE, "Enhanced Open (OWE)"), (.oweTransition, "Open/OWE"), (.dynamicWEP, "WEP"), (.WEP, "WEP"),
            (.none, "Open"),
        ]
        return order.first { n.supportsSecurity($0.0) }?.1
    }

    static func phy(_ n: CWNetwork, beacon: WiFiBeaconInfo) -> String? {
        let order: [(CWPHYMode, String)] = [(.mode11be, "802.11be (Wi-Fi 7)"), (.mode11ax, "802.11ax (Wi-Fi 6)"), (.mode11ac, "802.11ac (Wi-Fi 5)"),
                                           (.mode11n, "802.11n (Wi-Fi 4)"), (.mode11g, "802.11g"), (.mode11a, "802.11a"), (.mode11b, "802.11b")]
        if let p = order.first(where: { n.supportsPHYMode($0.0) }) { return p.1 }
        return beacon.standard.flatMap { s in order.first { $0.1.hasPrefix(s) }?.1 }
    }
}
