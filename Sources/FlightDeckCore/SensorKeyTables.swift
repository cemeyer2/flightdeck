import Foundation
// SMC temperature key → friendly name, per chip family. SMC keys are four characters; Apple documents none of them,
// and their meaning changes between chips (on Apple silicon "Tp0P" is a performance core on M1 Pro/Max, while on Intel
// it is the power supply). So only keys with a known meaning are listed, and only listed keys are read (each read is
// an SMC round trip of ~0.2 ms, and an M1 Max publishes ~250 temperature keys).
//
// Confidence, per table:
//   • common Apple silicon (battery, Wi-Fi, SSD, airflow, palm rest): the same keys appear on every Apple-silicon
//     MacBook seen; values checked on an M1 Max MacBook Pro against the HID battery and NAND sensors.
//   • M1 Pro/Max/Ultra per-core keys: the widely used open-source map (the one the Stats app ships); checked here on an
//     M1 Max: under an all-performance-core load the eight P keys warm ~12 °C while the two E keys warm least.
//   • M2, M3 and M4 per-core keys: the same open-source map, not verified on hardware by FlightDeck.
//   • base M1: no per-core SMC keys are listed; its HID sensors ("pACC/eACC MTR Temp Sensor…") already name the clusters.
//   • Intel: the classic keys every Intel Mac monitor uses (CPU die/proximity, PECI, per-core TC<n>C, GPU, battery…).

public struct SensorKeyEntry: Sendable, Equatable {
    public var name: String
    public var group: SensorGroup
}

public enum SensorKeyTables {
    /// HID product name that reports the same physical sensor as an SMC key (SMC key → HID name), for deduplication.
    /// Both are the battery pack's hottest reading and the SSD's NAND reading respectively.
    static let equivalents: [String: String] = ["TB0T": "gas gauge battery", "TH0x": "NAND CH0 temp"]

    public static func table(for chip: ChipFamily) -> [String: SensorKeyEntry] {
        switch chip {
        case .intel: return intel
        case .m1Pro: return common.merging(cores(p: m1ProP, e: m1ProE, gpu: m1ProGPU)) { a, _ in a }
        case .m2: return common.merging(cores(p: m2P, e: m2E, gpu: m2GPU)) { a, _ in a }
        case .m3: return common.merging(cores(p: m3P, e: m3E, gpu: m3GPU)) { a, _ in a }
        case .m4: return common.merging(cores(p: m4P, e: m4E, gpu: m4GPU)) { a, _ in a }
        case .m1, .appleSilicon: return common
        }
    }

    /// The keys PowerSampler reads on this chip.
    public static func keys(for chip: ChipFamily) -> [String] { table(for: chip).keys.sorted() }

    /// Numbered entries for per-core and per-GPU-cluster keys, in the order given ("P-core 1", "P-core 2", …).
    static func cores(p: [String], e: [String], gpu: [String]) -> [String: SensorKeyEntry] {
        var t: [String: SensorKeyEntry] = [:]
        for (i, k) in p.enumerated() { t[k] = SensorKeyEntry(name: "P-core \(i + 1)", group: .cpuPerformance) }
        for (i, k) in e.enumerated() { t[k] = SensorKeyEntry(name: "E-core \(i + 1)", group: .cpuEfficiency) }
        for (i, k) in gpu.enumerated() { t[k] = SensorKeyEntry(name: "GPU cluster \(i + 1)", group: .gpu) }
        return t
    }

    // MARK: Apple silicon

    /// Keys shared by Apple-silicon laptops. TB0T is the pack's hottest reading, TB1T/TB2T its two sensors; TH0x is
    /// the SSD's hottest NAND reading and TH0a/TH0b its sensors; TaLP/TaRF sit in the left and right airflow paths;
    /// Ts0P/Ts1P under the palm rests; TW0P on the wireless module.
    static let common: [String: SensorKeyEntry] = [
        "TB0T": .init(name: "Battery (hottest)", group: .battery),
        "TB1T": .init(name: "Battery sensor 1", group: .battery),
        "TB2T": .init(name: "Battery sensor 2", group: .battery),
        "TW0P": .init(name: "Wireless module", group: .wireless),
        "TH0x": .init(name: "SSD (hottest NAND)", group: .ssd),
        "TH0a": .init(name: "SSD sensor 1", group: .ssd),
        "TH0b": .init(name: "SSD sensor 2", group: .ssd),
        "TaLP": .init(name: "Airflow left", group: .ambient),
        "TaRF": .init(name: "Airflow right", group: .ambient),
        "Ts0P": .init(name: "Palm rest 1", group: .enclosure),
        "Ts1P": .init(name: "Palm rest 2", group: .enclosure),
    ]

    // M1 Pro / Max / Ultra: 8 performance cores, 2 efficiency cores, 4 GPU cluster sensors.
    static let m1ProP = ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
    static let m1ProE = ["Tp09", "Tp0T"]
    static let m1ProGPU = ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
    // M2 family
    static let m2P = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
    static let m2E = ["Tp1h", "Tp1t", "Tp1p", "Tp1l"]
    static let m2GPU = ["Tg0f", "Tg0j"]
    // M3 family
    static let m3P = ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
    static let m3E = ["Te05", "Te0L", "Te0P", "Te0S"]
    static let m3GPU = ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
    // M4 family
    static let m4P = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
    static let m4E = ["Te05", "Te0S", "Te09", "Te0H"]
    static let m4GPU = ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]

    // MARK: Intel

    /// Intel Macs: TC<n>C are per-core digital thermal sensors (n from 1), TCXC the package reading over PECI.
    static let intel: [String: SensorKeyEntry] = {
        var t: [String: SensorKeyEntry] = [
            "TC0D": .init(name: "CPU die", group: .cpu),
            "TC0E": .init(name: "CPU die (virtual)", group: .cpu),
            "TC0F": .init(name: "CPU die (filtered)", group: .cpu),
            "TC0H": .init(name: "CPU heatsink", group: .cpu),
            "TC0P": .init(name: "CPU proximity", group: .cpu),
            "TCXC": .init(name: "CPU package (PECI)", group: .cpu),
            "TG0D": .init(name: "GPU die", group: .gpu),
            "TG0P": .init(name: "GPU proximity", group: .gpu),
            "TCGC": .init(name: "Integrated GPU (PECI)", group: .gpu),
            "TPCD": .init(name: "Platform controller hub die", group: .soc),
            "TM0P": .init(name: "Memory proximity", group: .memory),
            "TH0P": .init(name: "SSD proximity", group: .ssd),
            "TB0T": .init(name: "Battery (hottest)", group: .battery),
            "TB1T": .init(name: "Battery sensor 1", group: .battery),
            "TB2T": .init(name: "Battery sensor 2", group: .battery),
            "TW0P": .init(name: "Wireless module", group: .wireless),
            "Tp0P": .init(name: "Power supply proximity", group: .power),
            "Ts0P": .init(name: "Palm rest", group: .enclosure),
            "TA0P": .init(name: "Ambient", group: .ambient),
        ]
        for i in 1...18 { t["TC\(i)C"] = .init(name: "CPU core \(i)", group: .cpu) }
        return t
    }()
}
