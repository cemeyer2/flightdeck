import Foundation

// Network map, part 3: guessing what kind of device something is. Evidence is weighed strongest first: what the
// device says about itself (Bonjour model and services), then the name it chose, then who made its network chip.
// Every guess carries the reason, and the view shows it, because a vendor-only guess ("Espressif makes Wi-Fi chips
// for smart plugs") is much weaker than "advertises _ipp._tcp".

public enum DeviceClassifier {
    public static func guess(_ d: NetDevice) -> (kind: DeviceKind, reason: String) {
        if d.isThisMac { return (.thisMac, "this Mac's own address") }
        if d.isGateway { return (.router, "default gateway in this Mac's routing table") }
        if let m = d.model, let k = fromModel(m) { return (k, "advertised model \"\(m)\"") }
        if let k = fromServices(d.services, model: d.model) { return k }
        let names = ([d.bonjourHost, d.hostname] + d.bonjourNames.map(Optional.some)).compactMap { $0 }
        for n in names { if let k = fromName(n) { return (k, "its name \"\(n)\"") } }
        if d.isIPv6Router { return (.router, "announces itself as an IPv6 router") }
        if let v = d.vendor.name, let k = fromVendor(v) { return (k, "made by \(v) (MAC vendor), which mostly makes \(k.rawValue.lowercased()) devices") }
        switch d.vendor {
        case .privateAddress: return (.unknown, "uses a private (randomized) MAC and advertises nothing identifying; usually a phone, tablet or laptop")
        case .known(let v): return (.unknown, "made by \(v), which makes many kinds of device")
        default: return (.unknown, "nothing identifying was seen")
        }
    }

    /// Model identifiers as advertised in TXT records. Apple's ("iPhone15,2", "MacBookPro18,3", "AppleTV14,1",
    /// "AudioAccessory5,1" = HomePod, "Watch6,1") are precise; other vendors' names are matched by keyword.
    static func fromModel(_ m: String) -> DeviceKind? {
        let s = m.lowercased()
        let table: [(String, DeviceKind)] = [
            ("iphone", .phone), ("ipod", .phone), ("ipad", .tablet), ("watch", .watch), ("appletv", .tv),
            ("audioaccessory", .speaker), ("homepod", .speaker),
            ("macbook", .computer), ("imac", .computer), ("macmini", .computer), ("macpro", .computer), ("mac", .computer),
            ("chromecast", .tv), ("google tv", .tv), ("shield", .tv), ("bravia", .tv), ("roku", .tv), ("fire tv", .tv),
            ("nest audio", .speaker), ("nest mini", .speaker), ("home mini", .speaker), ("google home", .speaker),
            ("nest hub", .smartHome), ("sonos", .speaker), ("echo", .speaker),
            ("printer", .printer), ("laserjet", .printer), ("officejet", .printer), ("deskjet", .printer), ("envy", .printer),
            ("pixma", .printer), ("ecotank", .printer), ("hl-", .printer), ("mfc-", .printer), ("dcp-", .printer),
            ("diskstation", .nas), ("ds2", .nas), ("ds9", .nas), ("rackstation", .nas), ("ts-", .nas),
            ("playstation", .console), ("xbox", .console), ("nintendo", .console),
        ]
        return table.first { s.hasPrefix($0.0) || s.contains($0.0) && $0.0.count > 4 }?.1
    }

    /// Service types that define a device class. Printing and scanning services are unambiguous; AirPlay/Cast
    /// receivers are TVs unless only audio is offered; file sharing alone could be any computer, so it only means
    /// NAS together with another hint (handled by the vendor step).
    static func fromServices(_ services: [String], model: String?) -> (kind: DeviceKind, reason: String)? {
        func has(_ t: String) -> Bool { services.contains { $0.hasPrefix(t + ".") } }
        func r(_ k: DeviceKind, _ t: String) -> (DeviceKind, String) { (k, "advertises \(t)") }
        for t in ["_ipp", "_ipps", "_printer", "_pdl-datastream", "_uscan", "_scanner"] where has(t) { return r(.printer, "a printing/scanning service (\(t))") }
        if has("_hap") || has("_homekit") || has("_matter") || has("_hue") { return r(.smartHome, "a HomeKit/Matter accessory service") }
        if has("_sonos") { return r(.speaker, "the Sonos service") }
        if has("_googlecast") { return r(.tv, "Google Cast (could also be a Cast speaker)") }
        if has("_airplay") { return r(.tv, "AirPlay video") }
        if has("_raop") || has("_spotify-connect") { return r(.speaker, "an audio receiver service (AirPlay audio / Spotify Connect)") }
        if has("_amzn-wplay") { return r(.tv, "Amazon's Fire TV service") }
        if has("_companion-link") { return r(.phone, "Apple's Continuity service (an iPhone, iPad or Mac)") }
        if has("_rfb") || has("_ssh") || has("_sftp-ssh") { return r(.computer, "remote login or screen sharing") }
        if has("_smb") || has("_afpovertcp") { return r(.computer, "file sharing") }
        return nil
    }

    /// Names devices give themselves by default ("Johns-iPhone", "DESKTOP-4F2K", "BRW3C2AF4", "Galaxy-S23").
    static func fromName(_ n: String) -> DeviceKind? {
        let s = n.lowercased()
        // Long keywords match anywhere in the name ("Johns-iPhone" → iphone)…
        let table: [(String, DeviceKind)] = [
            ("iphone", .phone), ("android", .phone), ("galaxy", .phone), ("pixel", .phone), ("oneplus", .phone),
            ("ipad", .tablet), ("watch", .watch),
            ("macbook", .computer), ("imac", .computer), ("mac-mini", .computer), ("macmini", .computer), ("desktop-", .computer), ("laptop", .computer),
            ("printer", .printer), ("epson", .printer),
            ("appletv", .tv), ("apple-tv", .tv), ("chromecast", .tv), ("roku", .tv), ("firetv", .tv), ("bravia", .tv),
            ("homepod", .speaker), ("sonos", .speaker),
            ("diskstation", .nas), ("synology", .nas),
            ("camera", .camera), ("playstation", .console), ("xbox", .console),
            ("thermostat", .smartHome), ("smartplug", .smartHome),
        ]
        if let k = table.first(where: { s.contains($0.0) })?.1 { return k }
        // …short ones only as a whole word, so "Jonas-PC" isn't taken for a NAS.
        let words = Set(s.split(whereSeparator: { "-_. '’".contains($0) }).map(String.init))
        let short: [(String, DeviceKind)] = [
            ("tv", .tv), ("echo", .speaker), ("nas", .nas), ("cam", .camera), ("ps4", .console), ("ps5", .console),
            ("hue", .smartHome), ("plug", .smartHome), ("bulb", .smartHome),
        ]
        if let k = short.first(where: { words.contains($0.0) })?.1 { return k }
        // Brother printers name themselves "BRW" + their MAC ("BRW3C2AF41B22C0").
        if s.hasPrefix("brw"), s.count == 15 { return .printer }
        return nil
    }

    /// Vendors whose products on a home network are nearly all one kind. Vendors that make many kinds (Apple,
    /// Samsung, Google, Amazon, chip makers) are deliberately absent.
    static func fromVendor(_ v: String) -> DeviceKind? {
        switch v {
        case "Roku", "Vizio", "TCL", "Hisense": .tv
        case "Sonos", "Bose", "Denon / Marantz": .speaker
        case "Brother", "Canon", "Epson", "Xerox", "Lexmark", "Ricoh", "Kyocera": .printer
        case "Synology", "QNAP", "Western Digital", "Seagate": .nas
        case "Philips Hue", "ecobee", "Aqara", "Shelly", "IKEA", "Tuya", "Espressif", "Belkin", "Nest", "Chamberlain",
             "iRobot", "Dyson", "Withings", "Netatmo": .smartHome
        case "Ring", "Wyze", "Arlo", "Hikvision", "EZVIZ", "Dahua", "Reolink": .camera
        case "Nintendo", "Valve": .console
        case "Ubiquiti", "eero", "Netgear", "TP-Link", "D-Link", "Zyxel", "AVM (FRITZ!)", "MikroTik", "Plume", "Cisco",
             "Cisco Meraki", "Linksys", "Arris / CommScope", "Sagemcom", "Vantiva / Technicolor": .networkGear
        case "Raspberry Pi": .computer
        default: nil
        }
    }
}
