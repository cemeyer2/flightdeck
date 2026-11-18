// Sensor catalog tests: chip detection, HID name and SMC key mapping per chip (this Mac's real M1 Max capture plus
// synthetic M1, M3 and Intel lists), deduplication between the sources, group maxima, and the per-sensor history.
import XCTest
@testable import FlightDeckCore

final class SensorCatalogTests: XCTestCase {
    func sensor(_ c: SensorCatalog, _ raw: String) -> CatalogSensor? { c.sensors.first { $0.raw == raw } }

    func testChipFamilyFromBrandString() {
        XCTAssertEqual(ChipFamily.from(brand: "Apple M1"), .m1)
        XCTAssertEqual(ChipFamily.from(brand: "Apple M1 Max"), .m1Pro)
        XCTAssertEqual(ChipFamily.from(brand: "Apple M1 Ultra"), .m1Pro)
        XCTAssertEqual(ChipFamily.from(brand: "Apple M2 Pro"), .m2)
        XCTAssertEqual(ChipFamily.from(brand: "Apple M3 Max"), .m3)
        XCTAssertEqual(ChipFamily.from(brand: "Apple M4"), .m4)
        XCTAssertEqual(ChipFamily.from(brand: "Apple M9"), .appleSilicon, "a chip the tables don't know gets only the common keys")
        XCTAssertEqual(ChipFamily.from(brand: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz"), .intel)
        XCTAssertEqual(ChipFamily.from(brand: ""), .appleSilicon)
    }

    /// This Mac's real capture: per-core SMC keys become P/E cores and GPU clusters, HID PMU dies become SoC sensors,
    /// undocumented keys and PMU sensors stay raw under Other.
    func testM1MaxFixtureMapping() throws {
        let c = SensorCatalog.build(hid: SensorFixtures.m1MaxHID, smc: SensorFixtures.m1MaxSMC, chip: .m1Pro)
        let p = c.sensors.filter { $0.group == .cpuPerformance }
        XCTAssertEqual(p.map(\.name), (1...8).map { "P-core \($0)" }, "eight performance cores, numerically ordered")
        XCTAssertEqual(sensor(c, "Tp01")?.name, "P-core 1")
        XCTAssertEqual(sensor(c, "Tp0b")?.name, "P-core 8")
        XCTAssertEqual(c.sensors.filter { $0.group == .cpuEfficiency }.map(\.raw), ["Tp09", "Tp0T"])
        XCTAssertEqual(c.sensors.filter { $0.group == .gpu }.map(\.name), ["GPU cluster 1", "GPU cluster 2", "GPU cluster 3", "GPU cluster 4"])
        XCTAssertEqual(sensor(c, "PMU tdie10")?.name, "Die 10")
        XCTAssertEqual(sensor(c, "PMU tdie10")?.group, .soc)
        XCTAssertEqual(sensor(c, "TW0P")?.group, .wireless)
        XCTAssertEqual(sensor(c, "Ts0P")?.group, .enclosure)
        XCTAssertEqual(sensor(c, "TaLP")?.group, .ambient)
        // Never guessed: undocumented keys and PMU sensors keep their raw names under Other.
        XCTAssertEqual(sensor(c, "TPD0")?.group, .other)
        XCTAssertEqual(sensor(c, "TPD0")?.name, "SMC TPD0")
        XCTAssertEqual(sensor(c, "PMU tdev1")?.name, "PMU tdev1")
        XCTAssertEqual(sensor(c, "PMU tdev1")?.group, .other)
        // Die order is numeric: "Die 2" before "Die 10".
        let dies = c.sensors.filter { $0.group == .soc }.map(\.name)
        XCTAssertLessThan(try XCTUnwrap(dies.firstIndex(of: "Die 2")), try XCTUnwrap(dies.firstIndex(of: "Die 10")))
        // tcal is a reference: listed, but never the hottest of anything.
        let tcal = try XCTUnwrap(sensor(c, "PMU tcal"))
        XCTAssertTrue(tcal.reference)
        XCTAssertNotEqual(c.reading(for: .other)?.hottest, tcal.name)
    }

    /// Every key the sampler reads on an M1 Max is present in the capture, so nothing in the table is unreachable.
    func testM1MaxReadKeysExistInCapture() {
        let captured = Set(SensorFixtures.m1MaxSMC.map(\.name))
        XCTAssertEqual(Set(SensorKeyTables.keys(for: .m1Pro)).subtracting(captured), [])
    }

    /// Deduplication: the HID battery and NAND sensors are the SMC's TB0T and TH0x; one entry each survives,
    /// named from the SMC table and noting the HID twin.
    func testDeduplicatesBatteryAndNAND() throws {
        let c = SensorCatalog.build(hid: SensorFixtures.m1MaxHID, smc: SensorFixtures.m1MaxSMC, chip: .m1Pro)
        XCTAssertNil(sensor(c, "gas gauge battery"))
        XCTAssertNil(sensor(c, "NAND CH0 temp"))
        XCTAssertEqual(sensor(c, "TB0T")?.alsoReportedAs, "gas gauge battery")
        XCTAssertEqual(sensor(c, "TH0x")?.alsoReportedAs, "NAND CH0 temp")
        XCTAssertEqual(Set(c.sensors.map(\.id)).count, c.sensors.count, "ids are unique")
    }

    /// Readings that disagree by more than the tolerance aren't the same sensor on this Mac: both are kept.
    func testNoDedupWhenReadingsDisagree() {
        let c = SensorCatalog.build(hid: [SensorReading(name: "gas gauge battery", celsius: 30)],
                                    smc: [SensorReading(name: "TB0T", celsius: 41)], chip: .m1Pro)
        XCTAssertEqual(c.sensors.filter { $0.group == .battery }.count, 2)
        XCTAssertNil(sensor(c, "TB0T")?.alsoReportedAs)
    }

    /// A base M1: clusters come from HID names; no per-core SMC key is named (Tp01 means something else there).
    func testSyntheticM1() {
        let c = SensorCatalog.build(hid: SensorFixtures.m1HID, smc: SensorFixtures.m1SMC, chip: .m1)
        XCTAssertEqual(sensor(c, "pACC MTR Temp Sensor9")?.name, "P-cluster sensor 9")
        XCTAssertEqual(sensor(c, "pACC MTR Temp Sensor9")?.group, .cpuPerformance)
        XCTAssertEqual(sensor(c, "eACC MTR Temp Sensor3")?.group, .cpuEfficiency)
        XCTAssertEqual(sensor(c, "GPU MTR Temp Sensor4")?.group, .gpu)
        XCTAssertEqual(sensor(c, "ANE MTR Temp Sensor1")?.name, "Neural Engine sensor 1")
        XCTAssertEqual(sensor(c, "PMGR SOC Die Temp Sensor0")?.group, .soc)
        XCTAssertEqual(sensor(c, "Tp01")?.group, .other)
        XCTAssertEqual(sensor(c, "Unknown Sensor X")?.group, .other)
        XCTAssertEqual(sensor(c, "Unknown Sensor X")?.name, "Unknown Sensor X")
        XCTAssertEqual(c.reading(for: .cpu)?.max, 51)
        XCTAssertEqual(c.reading(for: .cpuEfficiency)?.max, 41)
    }

    func testSyntheticM3() {
        let c = SensorCatalog.build(hid: [], smc: SensorFixtures.m3SMC, chip: .m3)
        XCTAssertEqual(c.sensors.filter { $0.group == .cpuEfficiency }.map(\.name), ["E-core 1", "E-core 2", "E-core 3", "E-core 4"])
        XCTAssertEqual(sensor(c, "Tf09")?.name, "P-core 2")
        XCTAssertEqual(sensor(c, "Tf14")?.group, .gpu)
        XCTAssertEqual(sensor(c, "Tp01")?.group, .other, "Tp01 isn't a core key on M3")
        XCTAssertEqual(c.families.first?.family, .cpu)
        XCTAssertEqual(c.families.first?.max, 57)
    }

    func testSyntheticIntel() {
        let c = SensorCatalog.build(hid: [], smc: SensorFixtures.intelSMC, chip: .intel)
        XCTAssertEqual(sensor(c, "TC10C")?.name, "CPU core 10")
        XCTAssertEqual(sensor(c, "TCXC")?.group, .cpu)
        XCTAssertEqual(sensor(c, "Tp0P")?.group, .power, "on Intel Tp0P is the power supply, not a core")
        XCTAssertEqual(sensor(c, "TPCD")?.group, .soc)
        XCTAssertEqual(sensor(c, "TZ9Q")?.group, .other)
        let names = c.sensors.filter { $0.group == .cpu }.map(\.name)
        XCTAssertLessThan(names.firstIndex(of: "CPU core 2")!, names.firstIndex(of: "CPU core 10")!)
        XCTAssertEqual(c.reading(for: .cpu)?.max, 63)
        XCTAssertEqual(c.reading(for: .cpu)?.hottest, "CPU package (PECI)")
    }

    func testFamiliesSummary() {
        let c = SensorCatalog.build(hid: SensorFixtures.m1MaxHID, smc: SensorFixtures.m1MaxSMC, chip: .m1Pro)
        let f = c.families.map(\.family)
        XCTAssertEqual(f, [.cpu, .gpu, .soc, .ssd, .battery, .wireless, .enclosure, .ambient], "only families with sensors, in order")
        XCTAssertEqual(c.reading(for: .cpu)?.count, 10, "8 P + 2 E")
    }

    // MARK: History

    func catalog(_ v: Double) -> SensorCatalog {
        SensorCatalog.build(hid: [SensorReading(name: "PMU tdie1", celsius: v)], smc: [], chip: .m1Pro)
    }

    func testMinMaxAverageAccumulation() throws {
        let h = SensorHistory(capacity: 4)
        let t0 = Date(timeIntervalSince1970: 1000)
        for (i, v) in [40.0, 50, 45, 65, 60].enumerated() { h.ingest(catalog(v), readAt: t0.addingTimeInterval(Double(i) * 4)) }
        let s = try XCTUnwrap(h.stats("hid:PMU tdie1"))
        XCTAssertEqual(s.min, 40); XCTAssertEqual(s.max, 65); XCTAssertEqual(s.average, 52, accuracy: 1e-9)
        XCTAssertEqual(s.count, 5); XCTAssertEqual(s.now, 60)
        // The ring keeps the last `capacity` points, oldest first, while the stats keep the whole session.
        XCTAssertEqual(h.series("hid:PMU tdie1"), [50, 45, 65, 60])
        XCTAssertEqual(h.stats("family:soc")?.max, 65)
    }

    /// Repeated values between sensor reads (same readAt) are not counted twice; a long pause inserts a gap point.
    func testRepeatedReadsAndGaps() throws {
        let h = SensorHistory(capacity: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(h.ingest(catalog(40), readAt: t0))
        XCTAssertFalse(h.ingest(catalog(40), readAt: t0))
        h.ingest(catalog(50), readAt: t0.addingTimeInterval(600))
        XCTAssertEqual(h.series("hid:PMU tdie1"), [40, nil, 50])
        XCTAssertEqual(h.stats("hid:PMU tdie1")?.count, 2)
        // A sensor that stops reporting keeps its stats but has no current value.
        h.ingest(SensorCatalog.build(hid: [], smc: [], chip: .m1Pro), readAt: t0.addingTimeInterval(604))
        XCTAssertNil(try XCTUnwrap(h.stats("hid:PMU tdie1")).now)
    }

    /// Live: this Mac's real sensors map to at least one known group. Skipped where there are none (CI VMs).
    func testLiveSensors() throws {
        let p = PowerSampler().sample()
        try XCTSkipIf(p.temperatures.isEmpty && (p.smcTemperatures ?? []).isEmpty, "no temperature sensors (virtual machine)")
        let c = SensorCatalog.build(p, chip: .current)
        XCTAssertFalse(c.families.isEmpty)
        XCTAssertTrue(c.sensors.allSatisfy { $0.celsius > 0 && $0.celsius < 150 })
    }
}
