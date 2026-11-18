import Foundation
// Charging insights: what the charger negotiated, the live power flow, and battery facts, parsed from the same
// AppleSmartBattery property dictionary PowerSampler already reads once per sample (no second IORegistry read).
// Keys vary by Mac model and macOS version, so every field is optional and nil means "not reported by this Mac".
// Units in the registry: mV, mA, mW and mAh; they are converted to V, A and W here. Several signed quantities
// (Amperage, BatteryPower) are published as unsigned 64-bit two's-complement numbers, so `ASB.signed` reinterprets them.

/// One USB Power Delivery offer from the charger ("source capability").
public struct PDOffer: Codable, Sendable, Hashable {
    /// fixed: one voltage. pps/avs: a programmable range from `minVolts` to `volts` (PD 3.0 PPS / PD 3.1 EPR AVS).
    public enum Kind: String, Codable, Sendable { case fixed, pps, avs }
    /// The index as reported: `UsbHvcMenu` "Index", or the 1-based PDO position for port-controller offers.
    public var index: Int
    public var kind: Kind
    /// Voltage (fixed) or maximum voltage (programmable), V.
    public var volts: Double
    public var minVolts: Double? = nil
    /// Maximum current, A (nil for AVS, which is limited by power instead).
    public var amps: Double?
    /// AVS: the offer's power limit (PDP), W. Otherwise volts × amps.
    public var pdpWatts: Double? = nil
    public var maxWatts: Double? { pdpWatts ?? amps.map { $0 * volts } }
}

/// Where the offer list came from.
public enum OfferSource: String, Codable, Sendable { case usbHvcMenu, portController }

/// The connected power adapter as AppleSmartBattery (or IOPSCopyExternalPowerAdapterDetails) describes it.
public struct AdapterReport: Codable, Sendable, Hashable {
    /// Rated wattage.
    public var watts: Int?
    /// Negotiated voltage and current (the contract in use), V and A.
    public var volts: Double?
    public var amps: Double?
    /// The voltage the adapter is supplying, V (AdapterVoltage; usually equals `volts`).
    public var adapterVolts: Double?
    public var name: String?
    public var manufacturer: String?
    public var adapterDescription: String?
    /// IOPS family code (IOPSKeys.h), e.g. USB-C PD. Stored signed (it is an IOKit error-style code).
    public var familyCode: Int64?
    public var isWireless: Bool?
    public var offers: [PDOffer] = []
    public var offersSource: OfferSource?
    /// The `index` of the offer in use (UsbHvcHvcIndex, or the RDO's object position).
    public var activeOfferIndex: Int?
    /// 0-based USB-C port controller carrying the contract, and how many controllers there are. Apple doesn't say
    /// which physical port a controller is, so this is shown as "port controller N of M".
    public var port: Int?
    public var portCount: Int?

    /// Negotiated V × A, W.
    public var negotiatedWatts: Double? { volts.flatMap { v in amps.map { v * $0 } } }
    public var activeOffer: PDOffer? { activeOfferIndex.flatMap { i in offers.first { $0.index == i } } }

    /// Names for the family codes in IOPSKeys.h: iokit_family_err(sub, code) = 0xE0000000 | sub << 14 | code.
    public var familyName: String? {
        guard let f = familyCode else { return nil }
        switch UInt32(truncatingIfNeeded: f) {
        case 0: return nil
        case 0xE0004000: return "USB host"
        case 0xE0004003: return "USB adapter"
        case 0xE0004004, 0xE0004005, 0xE0004006: return "USB charging port"
        case 0xE0004008: return "USB-C brick"
        case 0xE0004009: return "USB-C (Type-C current)"
        case 0xE000400A: return "USB-C Power Delivery"
        case 0xE0034000...0xE0034005: return "AC adapter (MagSafe/barrel)"
        default: return nil
        }
    }
}

/// PowerTelemetryData (Apple silicon laptops), in W/V/A. SystemLoad is what the Mac itself uses; SystemPowerIn is what
/// arrives from the adapter; BatteryPower is signed (+ charging, - draining).
public struct PowerTelemetry: Codable, Sendable, Hashable {
    public var systemPowerIn: Double?
    public var systemLoad: Double?
    public var batteryPower: Double?
    public var adapterEfficiencyLoss: Double?
    public var systemVoltageIn: Double?
    public var systemCurrentIn: Double?
}

/// ChargerData flags. Non-zero reason codes are undocumented bit fields, so they are shown raw, never interpreted.
public struct ChargerFlags: Codable, Sendable, Hashable {
    public var notChargingReason: Int64?
    public var slowChargingReason: Int64?
    /// Seconds charging has been thermally limited (TimeChargingThermallyLimited).
    public var thermallyLimited: Int64?
}

/// Battery facts beyond `BatteryInfo`. The serial number is deliberately not kept.
public struct BatteryFacts: Codable, Sendable, Hashable {
    /// Full-charge capacity the gauge currently measures, mAh (FullChargeCapacity / AppleRawMaxCapacity).
    public var fullChargeCapacity: Int?
    /// The figure macOS shows as Maximum Capacity, mAh.
    public var nominalCapacity: Int?
    public var designCapacity: Int?
    /// Cycles the battery is designed for (DesignCycleCount9C).
    public var designCycles: Int?
    /// Per-cell voltages, V, where the gauge publishes them.
    public var cellVoltages: [Double] = []
    public var gaugeName: String?
    /// "YYYY-MM-DD" from the packed ManufactureDate (Intel-era gauges); nil when not decodable.
    public var manufactureDate: String?
    public var fullyCharged: Bool?
}

/// Everything charging-related from one AppleSmartBattery read.
public struct ChargingDetails: Codable, Sendable, Hashable {
    /// nil when no adapter is connected (or it reports nothing).
    public var adapter: AdapterReport?
    public var telemetry: PowerTelemetry?
    public var charger: ChargerFlags?
    public var facts: BatteryFacts
    /// macOS's own time-to-full estimate, minutes; nil when absent or 65535 ("not calculated").
    public var avgTimeToFull: Int?
}

/// Helpers for AppleSmartBattery values.
public enum ASB {
    /// A signed 64-bit integer from an NSNumber that may hold the two's-complement bits as an unsigned value.
    public static func signed(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber else { return nil }
        // uint64Value yields the raw 64 bits whether the number was stored signed (-1308) or unsigned (2^64 - 1308).
        return Int64(bitPattern: n.uint64Value)
    }
    static func int(_ v: Any?) -> Int? { signed(v).map { Int($0) } }
    static func bool(_ v: Any?) -> Bool? { (v as? NSNumber)?.boolValue }
    /// Minutes, with 65535 ("still calculating") and negatives reported as nil.
    static func minutes(_ v: Any?) -> Int? { int(v).flatMap { $0 >= 0 && $0 < 65535 ? $0 : nil } }
}

extension ChargingDetails {
    /// Parses an AppleSmartBattery property dictionary. `externalConnected` gates the adapter and port: when unplugged,
    /// AdapterDetails holds only FamilyCode 0 and port controllers keep the stale last contract.
    public static func parse(_ d: [String: Any]) -> ChargingDetails {
        let bd = d["BatteryData"] as? [String: Any] ?? [:]
        func any(_ k: String) -> Any? { d[k] ?? bd[k] }
        let connected = ASB.bool(d["ExternalConnected"]) ?? false
        var facts = BatteryFacts()
        facts.fullChargeCapacity = ASB.int(bd["FullChargeCapacity"]) ?? ASB.int(any("AppleRawMaxCapacity"))
        facts.nominalCapacity = ASB.int(any("NominalChargeCapacity"))
        facts.designCapacity = ASB.int(any("DesignCapacity"))
        facts.designCycles = ASB.int(any("DesignCycleCount9C"))
        facts.cellVoltages = ((any("CellVoltage") as? [Any]) ?? []).compactMap { ASB.int($0) }.filter { $0 > 0 }.map { Double($0) / 1000 }
        facts.gaugeName = d["DeviceName"] as? String
        facts.manufactureDate = ASB.int(any("ManufactureDate")).flatMap(decodeManufactureDate)
        facts.fullyCharged = ASB.bool(any("FullyCharged"))

        var tel: PowerTelemetry?
        if let t = d["PowerTelemetryData"] as? [String: Any] {
            func w(_ k: String) -> Double? { ASB.signed(t[k]).map { Double($0) / 1000 } }
            tel = PowerTelemetry(systemPowerIn: w("SystemPowerIn"), systemLoad: w("SystemLoad"), batteryPower: w("BatteryPower"),
                                 adapterEfficiencyLoss: w("AdapterEfficiencyLoss"), systemVoltageIn: w("SystemVoltageIn"),
                                 systemCurrentIn: w("SystemCurrentIn"))
        }
        var flags: ChargerFlags?
        if let c = d["ChargerData"] as? [String: Any] {
            flags = ChargerFlags(notChargingReason: ASB.signed(c["NotChargingReason"]), slowChargingReason: ASB.signed(c["SlowChargingReason"]),
                                 thermallyLimited: ASB.signed(c["TimeChargingThermallyLimited"]))
        }
        var adapter: AdapterReport?
        if connected {
            // AdapterDetails is the chosen adapter; AppleRawAdapterDetails (a list) is the fallback on some models.
            let ad = (d["AdapterDetails"] as? [String: Any]) ?? ((d["AppleRawAdapterDetails"] as? [[String: Any]])?.first) ?? [:]
            var a = AdapterReport.parse(ad)
            // The USB-PD menu lives in AdapterDetails on Apple silicon and at the top level on some Intel Macs.
            if a.offers.isEmpty, let menu = d["UsbHvcMenu"] as? [Any] {
                a.offers = decodeMenu(menu); a.offersSource = a.offers.isEmpty ? nil : .usbHvcMenu
                a.activeOfferIndex = ASB.int(d["UsbHvcHvcIndex"])
            }
            if let ports = d["PortControllerInfo"] as? [[String: Any]] {
                let pc = portContract(ports)
                a.port = pc?.port; a.portCount = ports.count
                // Also when the menu doesn't contain the offer in use: Apple's 140 W charger lists only its 5–20 V offers
                // in UsbHvcMenu while supplying 28 V (a USB-PD 3.1 EPR offer) and reports UsbHvcHvcIndex 7, past the
                // menu's end. The port controller's own list includes the EPR offers, so it describes the contract.
                if let pc, !pc.offers.isEmpty, a.offers.isEmpty || a.activeOffer == nil {
                    a.offers = pc.offers; a.offersSource = .portController; a.activeOfferIndex = pc.position
                }
            }
            // Trust the voltage the adapter reports supplying over an offer index that disagrees with it. With Apple's
            // 140 W charger at 28 V (EPR), the port controller's contract record still names the 20 V offer; only
            // 28 V × 4.99 A gives the 140 W it delivers, so pick the offer that matches the measured voltage.
            if let v = a.adapterVolts ?? a.volts, abs((a.activeOffer?.volts ?? 0) - v) > 0.5,
               let match = a.offers.first(where: { $0.kind == .fixed && abs($0.volts - v) < 0.5 })
                   ?? a.offers.first(where: { $0.kind != .fixed && v >= ($0.minVolts ?? 0) - 0.5 && v <= $0.volts + 0.5 }) {
                a.activeOfferIndex = match.index
            }
            adapter = a.isEmpty ? nil : a
        }
        return ChargingDetails(adapter: adapter, telemetry: tel, charger: flags, facts: facts, avgTimeToFull: ASB.minutes(d["AvgTimeToFull"]))
    }

    /// Packed SBS ManufactureDate: day in bits 0-4, month in 5-8, year - 1980 in 9-15. Implausible values give nil.
    public static func decodeManufactureDate(_ v: Int) -> String? {
        let day = v & 0x1F, month = (v >> 5) & 0xF, year = 1980 + ((v >> 9) & 0x7F)
        guard v > 0, (1...31).contains(day), (1...12).contains(month), year >= 2000 else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// UsbHvcMenu entries: {Index, MaxVoltage mV, MaxCurrent mA}. Entries without a voltage are skipped.
    public static func decodeMenu(_ menu: [Any]) -> [PDOffer] {
        menu.enumerated().compactMap { i, e in
            guard let e = e as? [String: Any], let mv = ASB.int(e["MaxVoltage"]), mv > 0 else { return nil }
            return PDOffer(index: ASB.int(e["Index"]) ?? i, kind: .fixed, volts: Double(mv) / 1000,
                           amps: ASB.int(e["MaxCurrent"]).map { Double($0) / 1000 })
        }.sorted { $0.volts < $1.volts }
    }
}

extension AdapterReport {
    var isEmpty: Bool { watts == nil && volts == nil && name == nil && offers.isEmpty && (familyCode ?? 0) == 0 }

    /// AdapterDetails / IOPSCopyExternalPowerAdapterDetails keys: Watts, Voltage and Current (mV/mA), AdapterVoltage,
    /// Name, Manufacturer, Description, FamilyCode, IsWireless, UsbHvcMenu, UsbHvcHvcIndex.
    public static func parse(_ ad: [String: Any]) -> AdapterReport {
        var a = AdapterReport()
        a.watts = ASB.int(ad["Watts"]).flatMap { $0 > 0 ? $0 : nil }
        a.volts = ASB.int(ad["Voltage"]).flatMap { $0 > 0 ? Double($0) / 1000 : nil }
        a.amps = ASB.int(ad["Current"]).flatMap { $0 > 0 ? Double($0) / 1000 : nil }
        a.adapterVolts = ASB.int(ad["AdapterVoltage"]).flatMap { $0 > 0 ? Double($0) / 1000 : nil }
        a.name = ad["Name"] as? String; a.manufacturer = ad["Manufacturer"] as? String
        a.adapterDescription = ad["Description"] as? String
        a.familyCode = ASB.signed(ad["FamilyCode"]); a.isWireless = ASB.bool(ad["IsWireless"])
        if let menu = ad["UsbHvcMenu"] as? [Any] {
            a.offers = ChargingDetails.decodeMenu(menu)
            if !a.offers.isEmpty { a.offersSource = .usbHvcMenu; a.activeOfferIndex = ASB.int(ad["UsbHvcHvcIndex"]) }
        }
        return a
    }
}
