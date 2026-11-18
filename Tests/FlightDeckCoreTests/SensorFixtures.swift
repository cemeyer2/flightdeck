// Temperature sensor fixtures for the catalog tests. `m1MaxHID` and `m1MaxSMC` are a capture of this project's
// MacBookPro18,2 (Apple M1 Max, macOS 27.2) at idle: every HID temperature service's Product name (hottest instance kept,
// as ThermalSensors does) and every SMC key starting with "T" whose type is "flt " (values in °C, absent parts read 0;
// "ioft" keys, which aren't temperatures, are left out). The M1, M3 and Intel lists are synthetic: names and keys in
// the layouts those Macs publish, with made-up values.
import Foundation
@testable import FlightDeckCore

enum SensorFixtures {
    static func readings(_ pairs: [(String, Double)]) -> [SensorReading] { pairs.map { SensorReading(name: $0.0, celsius: $0.1) } }

    static let m1MaxHID = readings([
        ("NAND CH0 temp", 33), ("PMU TP0s", 40.86), ("PMU TP1g", 41.48), ("PMU TP1s", 41.21), ("PMU TP2g", 41.48), ("PMU TP2s", 41.04),
        ("PMU TP3g", 41.21), ("PMU tcal", 51.85), ("PMU tdev1", 40.44), ("PMU tdev2", 40), ("PMU tdev3", 40.51), ("PMU tdev4", 36.55),
        ("PMU tdev5", 32.91), ("PMU tdev6", 38.93), ("PMU tdev7", 41.16), ("PMU tdev8", 40.64), ("PMU tdie0", 41.48), ("PMU tdie1", 41.39),
        ("PMU tdie10", 41.57), ("PMU tdie2", 41.48), ("PMU tdie3", 41.48), ("PMU tdie4", 41.48), ("PMU tdie5", 41.3), ("PMU tdie6", 41.3),
        ("PMU tdie7", 41.3), ("PMU tdie8", 41.57), ("PMU tdie9", 41.66), ("gas gauge battery", 30.9),
    ])

    static let m1MaxSMC = readings([
        ("TAOL", 26.56), ("TB0T", 30.8), ("TB1T", 30.4), ("TB2T", 30.8), ("TC10", 46.11), ("TC11", 48.71),
        ("TC12", 47.1), ("TC13", 47.32), ("TC20", 43.6), ("TC21", 44.42), ("TC22", 44.49), ("TC23", 43.7),
        ("TC30", 43.9), ("TC31", 44.49), ("TC32", 44.54), ("TC33", 44.72), ("TC40", 45.06), ("TC41", 47.27),
        ("TC42", 45.44), ("TC43", 45.71), ("TC50", 43.95), ("TC51", 44.25), ("TC52", 44.32), ("TC53", 44.25),
        ("TCDX", 48.88), ("TCHP", 38.59), ("TCMb", 57.54), ("TCMz", 66.12), ("TD00", 26.7), ("TD01", 27.29),
        ("TD02", 26.24), ("TD03", 26.42), ("TD04", 25.79), ("TD10", 27.13), ("TD11", 28.88), ("TD12", 28.21),
        ("TD13", 29.11), ("TD14", 27.37), ("TD20", 29.05), ("TD21", 31.83), ("TD22", 30.05), ("TD23", 32.84),
        ("TD24", 29.17), ("TDBP", 30.75), ("TDCR", 33.12), ("TDEC", 32.25), ("TDEL", 31.19), ("TDER", 32.12),
        ("TDTP", 34), ("TDVx", 32.84), ("TDeL", 31.19), ("TDeR", 32.06), ("TH0a", 32.73), ("TH0b", 33.22),
        ("TH0x", 33.22), ("TH1a", 0), ("TH1b", 0), ("TMVR", 39.5), ("TPD0", 41.39), ("TPD1", 41.21),
        ("TPD2", 41.48), ("TPD3", 41.3), ("TPD4", 41.92), ("TPD5", 41.3), ("TPD6", 41.39), ("TPD7", 41.66),
        ("TPD8", 41.48), ("TPD9", 41.48), ("TPDX", 41.92), ("TPDa", 41.3), ("TPDb", 41.21), ("TPDc", 41.13),
        ("TPDd", 41.39), ("TPDe", 41.39), ("TPDf", 40.95), ("TPDg", 40.95), ("TPDh", 41.04), ("TPDi", 41.39),
        ("TPDj", 41.48), ("TPMP", 40.84), ("TPSP", 44.18), ("TPVD", 46.69), ("TRD0", 47.96), ("TRD1", 46.28),
        ("TRD2", 46.9), ("TRD3", 46.72), ("TRD4", 46.54), ("TRD5", 45.83), ("TRD6", 45.74), ("TRD7", 46.54),
        ("TRD8", 46.54), ("TRD9", 46.45), ("TRDX", 47.96), ("TRDa", 46.1), ("TRDb", 45.65), ("TRDc", 46.01),
        ("TRDd", 45.83), ("TRDe", 46.36), ("TRDf", 45.74), ("TRDg", 45.65), ("TRDh", 45.74), ("TRDi", 47.08),
        ("TRDj", 46.54), ("TS0P", 41.96), ("TSVR", 40.2), ("TSWR", 40.19), ("TSXR", 41.12), ("TVA0", 26.74),
        ("TVD0", 57.54), ("TVMD", 0), ("TVS0", 35), ("TVS1", 35.36), ("TVS2", 34.96), ("TVSx", 35.36),
        ("TVV0", 46.74), ("TW0P", 42.02), ("Ta00", 0), ("Ta01", 0), ("Ta02", 0), ("Ta04", 0),
        ("Ta05", 8.49), ("Ta06", 10.9), ("Ta08", 0), ("Ta09", 0), ("Ta0A", 0), ("Ta0C", 0),
        ("Ta0D", 8.4), ("Ta0E", 10.81), ("TaLP", 40.99), ("TaLT", 32.7), ("TaLW", 33.82), ("TaRF", 43.2),
        ("TaRT", 32.62), ("TaRW", 36.3), ("TaTP", 43.89), ("Td00", 41.71), ("Td01", 41.71), ("Td02", 42.81),
        ("Td04", 42.63), ("Td05", 42.63), ("Td06", 43.61), ("Td08", 42.87), ("Td09", 42.87), ("Td0A", 44.56),
        ("Td0C", 43.3), ("Td0D", 43.3), ("Td0E", 44.75), ("Td0G", 42.8), ("Td0H", 42.8), ("Td0I", 43.89),
        ("Td0K", 42.32), ("Td0L", 42.32), ("Td0M", 43.73), ("Te00", 44.19), ("Te01", 57.54), ("Te02", 63.75),
        ("Tg04", 43.51), ("Tg05", 52.71), ("Tg0C", 40.96), ("Tg0D", 50.16), ("Tg0K", 40.25), ("Tg0L", 49.45),
        ("Tg0S", 40.95), ("Tg0T", 50.15), ("Th00", 43.74), ("Th01", 51.08), ("Th02", 55.45), ("Th04", 42.92),
        ("Th05", 42.92), ("Th06", 43.84), ("Th08", 42.87), ("Th09", 42.87), ("Th0A", 43.28), ("Th0C", 41.83),
        ("Th0D", 49.17), ("Th0E", 51.11), ("Th0G", 41.98), ("Th0H", 41.98), ("Th0I", 42.36), ("Tm00", 42.78),
        ("Tm01", 42.78), ("Tm02", 43.95), ("Tm04", 41.89), ("Tm05", 41.89), ("Tm06", 43.19), ("Tm08", 43.03),
        ("Tm09", 43.03), ("Tm0A", 44), ("Tm0C", 41.73), ("Tm0D", 41.73), ("Tm0E", 42.53), ("Tp00", 46.47),
        ("Tp01", 55.47), ("Tp02", 64.05), ("Tp04", 46.65), ("Tp05", 55.62), ("Tp06", 66.12), ("Tp08", 42.95),
        ("Tp09", 51.93), ("Tp0A", 56.74), ("Tp0C", 45.54), ("Tp0D", 54.69), ("Tp0E", 64.95), ("Tp0G", 46.24),
        ("Tp0H", 55.34), ("Tp0I", 65.93), ("Tp0K", 44.03), ("Tp0L", 52.87), ("Tp0M", 60.12), ("Tp0O", 43.66),
        ("Tp0P", 52.56), ("Tp0Q", 63.16), ("Tp0S", 43.93), ("Tp0T", 52.99), ("Tp0U", 57.1), ("Tp0W", 44.49),
        ("Tp0X", 53.42), ("Tp0Y", 59.25), ("Tp0a", 43.23), ("Tp0b", 52.22), ("Tp0c", 62.32), ("Ts00", 45.34),
        ("Ts01", 45.34), ("Ts02", 48.53), ("Ts04", 43.32), ("Ts05", 43.32), ("Ts06", 45.22), ("Ts0P", 30),
        ("Ts1P", 29), ("Tz11", 0), ("Tz12", 0), ("Tz13", 0), ("Tz14", 0), ("Tz15", 0),
        ("Tz16", 0), ("Tz17", 0), ("Tz18", 0), ("Tz1j", 0),
    ])

    /// A base M1 (MacBook Air style): cluster sensors come from HID, so no per-core SMC keys are mapped.
    static let m1HID = readings([
        ("pACC MTR Temp Sensor0", 48), ("pACC MTR Temp Sensor1", 51), ("pACC MTR Temp Sensor2", 47), ("pACC MTR Temp Sensor9", 50),
        ("eACC MTR Temp Sensor0", 39), ("eACC MTR Temp Sensor3", 41), ("GPU MTR Temp Sensor1", 37), ("GPU MTR Temp Sensor4", 38),
        ("SOC MTR Temp Sensor0", 42), ("ANE MTR Temp Sensor1", 35), ("ISP MTR Temp Sensor5", 36), ("PMGR SOC Die Temp Sensor0", 44),
        ("PMU tdie1", 45), ("PMU tcal", 52), ("gas gauge battery", 29), ("NAND CH0 temp", 33), ("Unknown Sensor X", 31),
    ])
    static let m1SMC = readings([("TB0T", 29.4), ("TB1T", 29), ("TW0P", 36), ("Tp01", 50)])

    /// An M3 Pro: per-core keys in the "Te"/"Tf" layout.
    static let m3SMC = readings([
        ("Te05", 41), ("Te0L", 42), ("Te0P", 40), ("Te0S", 43), ("Tf04", 55), ("Tf09", 57), ("Tf0A", 56),
        ("Tf14", 47), ("Tf18", 48), ("TB1T", 30), ("TH0x", 36), ("Tp01", 50),
    ])

    /// An Intel MacBook Pro: no HID temperature services, everything from the SMC (sp78 values).
    static let intelSMC = readings([
        ("TC0P", 52), ("TC0D", 61), ("TCXC", 63), ("TC1C", 60), ("TC2C", 62), ("TC10C", 58), ("TG0D", 55), ("TCGC", 54),
        ("TB0T", 31), ("TM0P", 45), ("TW0P", 40), ("Tp0P", 44), ("Ts0P", 30), ("TA0P", 26), ("TPCD", 57), ("TZ9Q", 40),
    ])
}
