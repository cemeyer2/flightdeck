import Foundation
// The sensor catalog: turns the two raw temperature sources into friendly, grouped sensors for the Thermals page,
// alerts, the menu bar and the MCP `temperatures` tool.
//   • HID sensors (PowerSampler's IOHIDEventSystemClient read) have self-describing "Product" names such as
//     "PMU tdie1", "pACC MTR Temp Sensor0", "gas gauge battery" or "NAND CH0 temp"; they are mapped by name pattern.
//   • SMC temperature keys ("Tp01", "TB1T", "TW0P", …) mean different things on different chips, so they are mapped
//     through per-chip tables (SensorKeyTables.swift).
// Anything not in a table keeps its raw name under Other: a wrong friendly name is worse than an honest raw one.
// Pure (no system access), so tests can feed it fixtures from any Mac.

/// What a sensor measures. `family` folds the three CPU groups into one for summaries and alerts.
public enum SensorGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case cpuPerformance, cpuEfficiency, cpu, gpu, soc, memory, ssd, battery, wireless, power, enclosure, ambient, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cpuPerformance: "CPU performance cores"
        case .cpuEfficiency: "CPU efficiency cores"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .soc: "SoC / die"
        case .memory: "Memory"
        case .ssd: "SSD"
        case .battery: "Battery"
        case .wireless: "Wi-Fi / Bluetooth"
        case .power: "Charger / power"
        case .enclosure: "Palm rest / enclosure"
        case .ambient: "Ambient / airflow"
        case .other: "Other"
        }
    }
    /// Short label for the summary strip and the menu bar ("CPU 72°").
    public var short: String {
        switch self {
        case .cpuPerformance, .cpuEfficiency, .cpu: "CPU"
        case .gpu: "GPU"
        case .soc: "SoC"
        case .memory: "MEM"
        case .ssd: "SSD"
        case .battery: "BAT"
        case .wireless: "WIFI"
        case .power: "PWR"
        case .enclosure: "CASE"
        case .ambient: "AIR"
        case .other: "OTHER"
        }
    }
    /// The summary family: every CPU group is "CPU"; the others are their own family.
    public var family: SensorGroup { self == .cpuPerformance || self == .cpuEfficiency ? .cpu : self }
    /// Families in display order, for the "highest by group" strip and the alert settings.
    public static let families: [SensorGroup] = [.cpu, .gpu, .soc, .memory, .ssd, .battery, .wireless, .power, .enclosure, .ambient]
}

/// Which SMC key layout applies. Read from the CPU brand string ("Apple M1 Max", "Intel(R) Core(TM) i9-…").
public enum ChipFamily: String, Sendable, Codable {
    /// `m1` is the base M1; `m1Pro` covers M1 Pro, Max and Ultra, whose SMC per-core keys differ from the base chip's.
    case m1, m1Pro, m2, m3, m4, appleSilicon, intel
    public static func from(brand: String) -> ChipFamily {
        let b = brand.lowercased()
        if b.contains("intel") { return .intel }
        // "apple m1 pro" → generation "m1" plus a tier word; anything newer than the tables know is plain appleSilicon.
        let words = b.split(separator: " ").map(String.init)
        guard let gen = words.first(where: { $0.hasPrefix("m") && Int($0.dropFirst()) != nil }) else { return .appleSilicon }
        let tiered = words.contains("pro") || words.contains("max") || words.contains("ultra")
        switch gen {
        case "m1": return tiered ? .m1Pro : .m1
        case "m2": return .m2
        case "m3": return .m3
        case "m4": return .m4
        default: return .appleSilicon
        }
    }
    /// This Mac's family, read once.
    public static let current: ChipFamily = from(brand: Sysctl.string("machdep.cpu.brand_string") ?? "")
}

public enum SensorSource: String, Codable, Sendable { case hid, smc }

/// One catalogued sensor reading.
public struct CatalogSensor: Identifiable, Sendable, Hashable, Codable {
    /// Stable across reads: "hid:<product name>" or "smc:<key>".
    public var id: String
    public var name: String
    public var group: SensorGroup
    public var source: SensorSource
    /// The raw HID product name or SMC key.
    public var raw: String
    public var celsius: Double
    /// When the other source reported the same sensor (and it was dropped as a duplicate), its raw name.
    public var alsoReportedAs: String? = nil
    /// Calibration references (HID "tcal") read hotter than any real part; they are listed but excluded from maxima.
    public var reference = false
    public init(id: String, name: String, group: SensorGroup, source: SensorSource, raw: String, celsius: Double, reference: Bool = false) {
        self.id = id; self.name = name; self.group = group; self.source = source; self.raw = raw; self.celsius = celsius; self.reference = reference
    }
}

/// The highest reading in one family, for the summary strip, alerts and the menu bar.
public struct GroupReading: Sendable, Equatable {
    public var family: SensorGroup
    public var max: Double
    public var average: Double
    public var hottest: String
    public var count: Int
}

public struct SensorCatalog: Sendable {
    public var chip: ChipFamily
    /// Sorted by group (enum order), then by name with numbers compared numerically ("core 2" before "core 10").
    public var sensors: [CatalogSensor]
    public init(chip: ChipFamily, sensors: [CatalogSensor]) { self.chip = chip; self.sensors = sensors }

    /// Catalogues one power sample: its HID sensors plus its SMC temperature keys.
    public static func build(_ p: PowerSample, chip: ChipFamily) -> SensorCatalog {
        build(hid: p.temperatures, smc: p.smcTemperatures ?? [], chip: chip)
    }

    public static func build(hid: [SensorReading], smc: [SensorReading], chip: ChipFamily) -> SensorCatalog {
        var out = hid.map(mapHID)
        let table = SensorKeyTables.table(for: chip)
        let smcSensors = smc.map { r -> CatalogSensor in
            let e = table[r.name]
            return CatalogSensor(id: "smc:" + r.name, name: e?.name ?? "SMC \(r.name)", group: e?.group ?? .other, source: .smc, raw: r.name, celsius: r.celsius)
        }
        // Deduplicate: where a known HID name and SMC key are the same physical sensor and agree within
        // `duplicateTolerance`, keep the SMC entry (its table name is more specific) and note the HID name on it.
        // Readings that disagree by more are kept apart: then they are evidently not the same sensor on this Mac.
        for var s in smcSensors {
            if let twin = SensorKeyTables.equivalents[s.raw],
               let i = out.firstIndex(where: { $0.source == .hid && $0.raw == twin && abs($0.celsius - s.celsius) <= duplicateTolerance }) {
                s.alsoReportedAs = out[i].raw
                out.remove(at: i)
            }
            out.append(s)
        }
        let order = Dictionary(uniqueKeysWithValues: SensorGroup.allCases.enumerated().map { ($1, $0) })
        out.sort { a, b in
            a.group != b.group ? order[a.group]! < order[b.group]! : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return SensorCatalog(chip: chip, sensors: out)
    }

    /// Two sources' readings of the same sensor are taken at slightly different moments, so allow a little drift.
    static let duplicateTolerance = 2.0

    /// Groups in display order with their sensors.
    public var grouped: [(group: SensorGroup, sensors: [CatalogSensor])] {
        SensorGroup.allCases.compactMap { g in
            let s = sensors.filter { $0.group == g }
            return s.isEmpty ? nil : (g, s)
        }
    }

    /// The hottest non-reference reading per family, in `SensorGroup.families` order. Families without sensors are left out.
    public var families: [GroupReading] {
        SensorGroup.families.compactMap { reading(for: $0) }
    }

    /// One family's reading (or, for a non-family group such as `.cpuPerformance`, just that group's).
    public func reading(for g: SensorGroup) -> GroupReading? {
        let s = sensors.filter { !$0.reference && (g == g.family ? $0.group.family == g : $0.group == g) }
        guard let top = s.max(by: { $0.celsius < $1.celsius }) else { return nil }
        return GroupReading(family: g, max: top.celsius, average: s.map(\.celsius).reduce(0, +) / Double(s.count), hottest: top.name, count: s.count)
    }

    // MARK: HID names

    /// Maps one HID product name. Patterns are the names Apple's sensor drivers publish; the trailing number (if any)
    /// becomes the sensor's index. Unknown names stay raw under Other.
    static func mapHID(_ r: SensorReading) -> CatalogSensor {
        let n = r.name
        func make(_ name: String, _ g: SensorGroup, reference: Bool = false) -> CatalogSensor {
            CatalogSensor(id: "hid:" + n, name: name, group: g, source: .hid, raw: n, celsius: r.celsius, reference: reference)
        }
        let num = trailingNumber(n)
        func indexed(_ base: String) -> String { num.map { "\(base) \($0)" } ?? base }
        // PMU / PMU2: the power-management unit's die sensors on the SoC. Macs with two dies (Ultra) or a second PMU
        // publish "PMU2 …"; those get a suffix so the two sets don't collide.
        let pmu2 = n.hasPrefix("PMU2 ")
        let suffix = pmu2 ? " (PMU 2)" : ""
        if n.hasPrefix("PMU ") || pmu2 {
            let rest = n.dropFirst(pmu2 ? 5 : 4)
            if rest.hasPrefix("tcal") { return make("Calibration reference" + suffix, .other, reference: true) }
            if rest.hasPrefix("tdie") { return make(indexed("Die") + suffix, .soc) }
            // "tdev" and "TP…" are further PMU sensors whose placement Apple doesn't document: kept raw.
            return make(n, .other)
        }
        if n.hasPrefix("pACC MTR Temp Sensor") { return make(indexed("P-cluster sensor"), .cpuPerformance) }
        if n.hasPrefix("eACC MTR Temp Sensor") { return make(indexed("E-cluster sensor"), .cpuEfficiency) }
        if n.hasPrefix("GPU MTR Temp Sensor") { return make(indexed("GPU sensor"), .gpu) }
        if n.hasPrefix("SOC MTR Temp Sensor") { return make(indexed("SoC sensor"), .soc) }
        if n.hasPrefix("ANE MTR Temp Sensor") { return make(indexed("Neural Engine sensor"), .soc) }
        if n.hasPrefix("ISP MTR Temp Sensor") { return make(indexed("Image processor sensor"), .soc) }
        if n.hasPrefix("PMGR SOC Die Temp Sensor") { return make(indexed("Power manager die"), .soc) }
        if n == "gas gauge battery" { return make("Battery (gas gauge)", .battery) }
        if n.hasPrefix("NAND CH"), n.hasSuffix(" temp") { return make(indexed("SSD NAND channel"), .ssd) }
        return make(n, .other)
    }

    /// The number at the end of a name, ignoring a trailing " temp": "Sensor0" → 0, "NAND CH1 temp" → 1, "tdie10" → 10.
    static func trailingNumber(_ s: String) -> Int? {
        let t = s.hasSuffix(" temp") ? String(s.dropLast(5)) : s
        let digits = t.reversed().prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(String(digits.reversed()))
    }
}
