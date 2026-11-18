// The UniFi data model: what FlightDeck knows about a UniFi network after one poll of its console, independent of which
// API it came from. Decoders (UniFiDecoding*.swift) fill it from the official Network Integration API and/or the classic
// controller API; UniFiTopology.swift turns its uplink fields into a tree.
//
// For other features (e.g. the network map): every device and client is keyed by its normalized MAC address
// (lowercase, colon-separated, see `UniFi.normalizeMAC`), and `UniFiSnapshot.attachment(ofMAC:)` answers "which AP or
// which switch port is this MAC on?", which is the real layer-2 topology that ARP or traceroute can't infer.
//
// Rule: nothing is invented. A field the console didn't report is nil, and views show it as unknown. A field that the
// API in use never provides is listed in `UniFiSnapshot.notes`, so the UI can say "not provided" instead of "—".
import Foundation

/// Which API a snapshot was read from.
public enum UniFiAPIKind: String, Codable, Sendable, Hashable {
    /// Official Network Integration API (`/proxy/network/integration/v1`, `X-API-KEY`).
    case integration
    /// Classic controller API (`/api/s/<site>/stat/...`), with a session cookie or an API key.
    case classic
    /// Integration API for the inventory, enriched with classic `stat/*` data (same API key) where the console allows.
    case integrationAndClassic
    /// Invented demo data (`-demo YES`).
    case demo
}

public struct UniFiSite: Codable, Sendable, Hashable, Identifiable {
    /// Integration API: a UUID. Classic API: the internal name (e.g. "default"), which is also what URLs use.
    public var id: String
    /// The short internal name used by classic URLs ("default"); the integration API calls it `internalReference`.
    public var name: String?
    /// Human-readable name ("Default", "Home").
    public var description: String?
    public init(id: String, name: String? = nil, description: String? = nil) { self.id = id; self.name = name; self.description = description }
}

public enum UniFiDeviceKind: String, Codable, Sendable, Hashable {
    case gateway, `switch`, accessPoint, other
}

/// How a device or client reaches the network: the MAC of the device it hangs off and, for wired links, the port.
public struct UniFiUplink: Codable, Sendable, Hashable {
    /// Normalized MAC of the upstream UniFi device (switch, gateway or, for a meshed AP, another AP).
    public var parentMAC: String?
    /// Port number on the parent the link is plugged into (classic `uplink_remote_port`, client `sw_port`).
    public var parentPort: Int?
    /// This device's own port used for the uplink (classic `uplink.port_idx`).
    public var localPort: Int?
    /// Negotiated link speed in Mbit/s, when reported.
    public var speedMbps: Int?
    /// True for a wireless (mesh) uplink.
    public var wireless: Bool?
    public init(parentMAC: String? = nil, parentPort: Int? = nil, localPort: Int? = nil, speedMbps: Int? = nil, wireless: Bool? = nil) {
        self.parentMAC = parentMAC; self.parentPort = parentPort; self.localPort = localPort; self.speedMbps = speedMbps; self.wireless = wireless
    }
}

public struct UniFiTemperature: Codable, Sendable, Hashable {
    public var name: String
    public var celsius: Double
    public init(name: String, celsius: Double) { self.name = name; self.celsius = celsius }
}

/// One switch or gateway port.
public struct UniFiPort: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var name: String?
    public var up: Bool?
    public var speedMbps: Int?
    public var maxSpeedMbps: Int?
    public var fullDuplex: Bool?
    public var poeEnabled: Bool?
    /// Power currently delivered over PoE, in watts.
    public var poeWatts: Double?
    /// "802.3at", "802.3bt", "24V passive"… as reported.
    public var poeStandard: String?
    /// True when this port is the device's own uplink.
    public var isUplink: Bool?
    public var rxBytes: UInt64?
    public var txBytes: UInt64?
    public init(index: Int) { self.index = index }
}

/// One access-point radio.
public struct UniFiRadio: Codable, Sendable, Hashable {
    /// "2.4 GHz", "5 GHz", "6 GHz".
    public var band: String?
    public var channel: Int?
    public var widthMHz: Int?
    /// Channel utilization (busy airtime) in percent.
    public var utilizationPercent: Double?
    public var clientCount: Int?
    public var txPowerDbm: Int?
    /// "802.11ax" etc.
    public var standard: String?
    public init(band: String? = nil) { self.band = band }
}

public struct UniFiDevice: Codable, Sendable, Hashable, Identifiable {
    /// Normalized MAC address; the key used for topology.
    public var id: String { mac }
    public var mac: String
    /// Integration API device UUID, used to match its `uplinkDeviceId` references.
    public var apiID: String?
    public var name: String?
    public var model: String?
    public var kind: UniFiDeviceKind
    public var ip: String?
    public var firmware: String?
    public var uptime: TimeInterval?
    /// As reported ("ONLINE", "connected", "disconnected", "upgrading"…).
    public var state: String?
    public var online: Bool?
    public var cpuPercent: Double?
    public var memoryPercent: Double?
    public var temperatures: [UniFiTemperature] = []
    public var ports: [UniFiPort] = []
    public var radios: [UniFiRadio] = []
    public var uplink: UniFiUplink?
    /// Clients connected to this device, as the console counts them.
    public var clientCount: Int?
    public var rxBps: Double?
    public var txBps: Double?
    public init(mac: String, kind: UniFiDeviceKind) { self.mac = mac; self.kind = kind }
    public var displayName: String { name ?? model ?? mac }
}

public struct UniFiClient: Codable, Sendable, Hashable, Identifiable {
    public var id: String { mac }
    public var mac: String
    /// Integration API client UUID.
    public var apiID: String?
    /// User-assigned alias, if any.
    public var name: String?
    public var hostname: String?
    public var ip: String?
    /// Manufacturer from the console's OUI database.
    public var vendor: String?
    /// nil when the console didn't say.
    public var wired: Bool?
    // Wireless attachment
    public var apMAC: String?
    public var ssid: String?
    /// Signal strength in dBm (negative; e.g. -58).
    public var signalDbm: Int?
    /// UniFi's "RSSI": signal above the noise floor, in dB (a positive number, higher is better).
    public var rssi: Int?
    public var channel: Int?
    /// "802.11ax (Wi-Fi 6)" style, built from the classic `radio_proto`.
    public var wifiStandard: String?
    public var band: String?
    // Wired attachment
    public var switchMAC: String?
    public var switchPort: Int?
    /// Wired link speed, or the Wi-Fi PHY rate, in Mbit/s.
    public var linkSpeedMbps: Int?
    /// Bytes this client downloaded / uploaded during the session (from the client's point of view).
    public var downloadBytes: UInt64?
    public var uploadBytes: UInt64?
    /// Current download / upload rates in bytes per second.
    public var downloadBps: Double?
    public var uploadBps: Double?
    public var uptime: TimeInterval?
    /// Integration API: the device the client is attached to (AP or switch), when only that is known.
    public var uplinkDeviceID: String?
    public init(mac: String) { self.mac = mac }

    public var displayName: String { name ?? hostname ?? ip ?? mac }
    /// The UniFi device this client hangs off: its AP when wireless, otherwise its switch.
    public var parentMAC: String? { wired == false ? (apMAC ?? switchMAC) : (switchMAC ?? apMAC) }
    /// Download + upload rate, for "busiest" sorting; nil if neither is known.
    public var totalBps: Double? { downloadBps == nil && uploadBps == nil ? nil : (downloadBps ?? 0) + (uploadBps ?? 0) }
}

public struct UniFiSpeedTest: Codable, Sendable, Hashable {
    public var downloadMbps: Double?
    public var uploadMbps: Double?
    public var latencyMs: Double?
    public var time: Date?
    public init(downloadMbps: Double? = nil, uploadMbps: Double? = nil, latencyMs: Double? = nil, time: Date? = nil) {
        self.downloadMbps = downloadMbps; self.uploadMbps = uploadMbps; self.latencyMs = latencyMs; self.time = time
    }
}

/// WAN and subsystem health. Every field is optional because consoles report different subsets.
public struct UniFiHealth: Codable, Sendable, Hashable {
    public var wanIP: String?
    public var isp: String?
    /// WAN receive (download) and transmit (upload) rates in bytes per second.
    public var wanRxBps: Double?
    public var wanTxBps: Double?
    public var latencyMs: Double?
    public var packetLossPercent: Double?
    public var wanUptime: TimeInterval?
    /// Per-subsystem status as reported ("wan": "ok", "wlan": "ok", "lan": "warning"…).
    public var subsystems: [String: String] = [:]
    public var speedTest: UniFiSpeedTest?
    public init() {}
}

public struct UniFiSnapshot: Codable, Sendable, Hashable {
    public var time: Date
    public var source: UniFiAPIKind
    public var site: UniFiSite?
    public var sites: [UniFiSite] = []
    public var devices: [UniFiDevice] = []
    public var clients: [UniFiClient] = []
    public var health = UniFiHealth()
    /// Plain-English notes about data the console didn't provide (e.g. "Per-client traffic isn't provided by the
    /// Integration API on this console").
    public var notes: [String] = []
    public init(time: Date, source: UniFiAPIKind) { self.time = time; self.source = source }

    public func device(mac: String) -> UniFiDevice? { devices.first { $0.mac == UniFi.normalizeMAC(mac) } }
    public var gateway: UniFiDevice? { devices.first { $0.kind == .gateway } }
}
