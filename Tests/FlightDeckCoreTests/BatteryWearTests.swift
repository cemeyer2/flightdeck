import XCTest
@testable import FlightDeckCore

/// Wear accumulation (through DailyLog, as the app does it), backward-compatible decoding, the power-log seed from a
/// fixture captured on a MacBook Pro, and the wear summary's levels.
final class BatteryWearTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func snap(_ i: Int, pct: Double, plugged: Bool, charging: Bool = false, temp: Double? = 30) -> Snapshot {
        var s = BlackBoxTests.base
        s.time = t0.addingTimeInterval(Double(i) * 10)
        s.power.battery = BatteryInfo(percent: pct, isCharging: charging, externalConnected: plugged, cycleCount: 100,
                                      maxCapacity: 9000, designCapacity: 10_000, temperature: temp)
        s.power.charging = nil
        s.power.powerSource = plugged ? "AC Power" : "Battery"
        s.processes = []
        return s
    }

    func testAccumulation() throws {
        let log = DailyLog(dir: nil)
        var i = 0
        func feed(_ pct: Double, plugged: Bool, charging: Bool = false, temp: Double? = 30) { log.ingest(snap(i, pct: pct, plugged: plugged, charging: charging, temp: temp)); i += 1 }
        for _ in 0..<10 { feed(100, plugged: true, temp: 36) }        // 9 steps at full: high charge, warm
        for _ in 0..<5 { feed(80, plugged: true, temp: 41) }          // held at 80% (plugged, not charging), hot
        for _ in 0..<5 { feed(60, plugged: true, charging: true) }    // charging: neither high nor held
        for p in [25.0, 19, 15, 9, 21, 18] { feed(p, plugged: false) } // one discharge below 20 (18 isn't re-armed), one below 10
        for p in [35.0, 15] { feed(p, plugged: false) }               // back above 30%, then below 20 again
        let w = try XCTUnwrap(log.history().days.last?.batteryWear)
        XCTAssertEqual(w.observedSeconds, Double(i - 1) * 10)
        XCTAssertEqual(w.pluggedSeconds, 190)            // steps 1…19 were plugged in
        XCTAssertEqual(w.pluggedHighSeconds, 90)
        XCTAssertEqual(w.heldSeconds, 50)
        XCTAssertEqual(w.above35Seconds, 140)            // steps at 36 °C and 41 °C
        XCTAssertEqual(w.above40Seconds, 50)
        XCTAssertEqual(w.tempMax, 41)
        XCTAssertEqual(w.dischargesBelow20, 2)
        XCTAssertEqual(w.dischargesBelow10, 1)
        XCTAssertEqual(w.minPercent, 9)
        // The day's battery point carries the tallies, health and cycles.
        let b = try XCTUnwrap(log.batteryHistory().days.last)
        XCTAssertEqual(try XCTUnwrap(b.health), 90, accuracy: 1e-9)
        XCTAssertEqual(b.cycles, 100)
        XCTAssertEqual(b.wear, w)
    }

    func testDesktopAccumulatesNothing() {
        let log = DailyLog(dir: nil)
        var s = snap(0, pct: 50, plugged: true); s.power.battery = nil
        log.ingest(s)
        XCTAssertNil(log.history().days.last?.batteryWear)
        XCTAssertTrue(log.batteryHistory().days.isEmpty)
    }

    // MARK: Decoding

    /// A record written before `batteryWear` existed still decodes (nil), and a wear tally missing newer fields
    /// decodes with zeros.
    func testBackwardCompatibleDecoding() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        var r = DayRecord(day: "2027-01-15", start: t0); r.batteryHealth = 91; r.cycleCount = 120
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: enc.encode(r)) as? [String: Any])
        obj.removeValue(forKey: "batteryWear")
        let old = try dec.decode(DayRecord.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(old.batteryWear); XCTAssertEqual(old.batteryHealth, 91)

        let partial = try dec.decode(BatteryWearDay.self, from: Data(#"{"pluggedSeconds": 3600, "dischargesBelow20": 2}"#.utf8))
        XCTAssertEqual(partial.pluggedSeconds, 3600); XCTAssertEqual(partial.dischargesBelow20, 2)
        XCTAssertEqual(partial.heldSeconds, 0); XCTAssertNil(partial.tempMax)
        XCTAssertEqual(try dec.decode(BatteryWearDay.self, from: Data("{}".utf8)), BatteryWearDay())

        // A daily-log.json from before the long-term battery points: loads, and its days feed the battery history.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file: [String: Any] = ["version": 1, "days": [obj]]
        try JSONSerialization.data(withJSONObject: file).write(to: dir.appendingPathComponent("daily-log.json"))
        let log = DailyLog(dir: dir)
        XCTAssertEqual(log.history().days.count, 1)
        XCTAssertEqual(log.batteryHistory().days.map(\.cycles), [120])
    }

    // MARK: Power-log seed

    /// Rows of PLBatteryAgent_EventNone_BatteryConfig captured from a MacBook Pro (macOS 26, design capacity 8694 mAh),
    /// columns as `PowerLogBattery.query` keeps them.
    static let powerLogRows: [[String: Double]] = [
        (1794202636, 876, 7508, 87, 44, -5, 28670), (1794291991, 878, 7528, 87, 44, -5, 28700),
        (1794379776, 879, 7504, 87, 44, -5, 28720), (1794466623, 881, 7497, 87, 44, -5, 28750),
        (1794602044, 882, 7550, 87, 44, -5, 28780), (1794724893, 884, 7524, 87, 44, -5, 28820),
        (1794824707, 886, 7583, 87, 44, -5, 28840), (1794913421, 887, 7509, 87, 44, -5, 28870),
        (1795000712, 889, 7498, 87, 44, -5, 28890), (1795088395, 889, 7613, 87, 44, -5, 28920),
    ].map { (r: (Double, Double, Double, Double, Double, Double, Double)) in
        ["timestamp": r.0, "CycleCount": r.1, "NominalChargeCapacity": r.2, "MaximumCapacityPercent": r.3,
         "MaximumTemperature": r.4, "MinimumTemperature": r.5, "TotalOperatingTime": r.6]
    }

    func testPowerLogParse() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let seed = PowerLogBattery.parse(Self.powerLogRows, designCapacity: 8694, calendar: cal)
        XCTAssertEqual(seed.days.count, 10)
        XCTAssertTrue(seed.days.allSatisfy { $0.source == .macOS })
        XCTAssertEqual(try XCTUnwrap(seed.days.first?.health), 7508.0 / 8694 * 100, accuracy: 1e-9)
        XCTAssertEqual(seed.days.first?.cycles, 876)
        XCTAssertEqual(seed.lifetime?.maxTemp, 44); XCTAssertEqual(seed.lifetime?.minTemp, -5); XCTAssertEqual(seed.lifetime?.operatingHours, 28_920)
        // Without a design capacity, the gauge's whole-percent figure is used.
        XCTAssertEqual(PowerLogBattery.parse(Self.powerLogRows, designCapacity: nil, calendar: cal).days.first?.health, 87)
        // Placeholder values are dropped, not shown.
        let junk = PowerLogBattery.parse([["timestamp": 1_795_000_000, "MaximumTemperature": 6553]], designCapacity: nil)
        XCTAssertNil(junk.lifetime); XCTAssertTrue(junk.days.isEmpty)
    }

    /// Seeded days fill gaps only: a day FlightDeck measured keeps its own reading.
    func testSeedNeverReplacesOwnReadings() throws {
        let log = DailyLog(dir: nil)
        log.ingest(snap(0, pct: 50, plugged: true))   // today: 90% from FlightDeck
        let today = try XCTUnwrap(log.batteryHistory().days.last)
        let seeded = [BatteryDay(day: today.day, start: today.start, health: 70, cycles: 1, source: .macOS),
                      BatteryDay(day: "2020-01-01", start: Date(timeIntervalSince1970: 1_577_880_000), health: 99, cycles: 3, source: .macOS)]
        log.seedBattery(PowerLogSeed(days: seeded, lifetime: nil))
        let h = log.batteryHistory().days
        XCTAssertEqual(h.count, 2)
        XCTAssertEqual(h.last?.health, 90); XCTAssertEqual(h.last?.source, .flightDeck)
    }

    /// The real power log, when this Mac has one (CI's VMs have no battery and skip).
    func testLivePowerLog() throws {
        guard FileManager.default.isReadableFile(atPath: PowerLogBattery.path) else { throw XCTSkip("no readable power log on this Mac") }
        guard let seed = PowerLogBattery.read(designCapacity: nil) else { throw XCTSkip("power log has no battery rows (no battery?)") }
        for d in seed.days { if let h = d.health { XCTAssertTrue((50...110).contains(h), "\(h)") } }
    }

    // MARK: Summary

    func testSummaryLevelsAndTips() throws {
        var w = BatteryWearDay()
        w.observedSeconds = 10 * 3600; w.pluggedSeconds = 8 * 3600; w.pluggedHighSeconds = 5.6 * 3600
        w.tempSeconds = 10 * 3600; w.tempSum = 30 * w.tempSeconds; w.tempMax = 38; w.above35Seconds = 600
        let days = (0..<5).map { BatteryDay(day: "d\($0)", start: t0.addingTimeInterval(Double($0) * 86_400), health: 90, cycles: 100 + $0, wear: w, source: .flightDeck) }
        let s = BatteryWearSummary.compute(days, cyclesPerWeek: 7.5, designCycles: 1000, cyclesRemaining: 896)
        func f(_ k: WearFactor.Kind) throws -> WearFactor { try XCTUnwrap(s.factors.first { $0.kind == k }) }
        XCTAssertEqual(try f(.highCharge).level, .high)
        XCTAssertTrue(try XCTUnwrap(f(.highCharge).tip).contains("70% of plugged-in time"))
        XCTAssertEqual(try f(.heat).level, .low)
        XCTAssertEqual(try f(.deepDischarge).level, .low)
        XCTAssertEqual(try f(.cycling).level, .high)
        XCTAssertEqual(try f(.chargeHold).level, .moderate)   // never held while sitting near full
        // Too little observation: unknown, never a share of almost nothing.
        var tiny = w; tiny.observedSeconds = 600; tiny.pluggedSeconds = 600; tiny.tempSeconds = 600
        let u = BatteryWearSummary.compute([BatteryDay(day: "x", start: t0, health: 90, cycles: 1, wear: tiny, source: .flightDeck)],
                                           cyclesPerWeek: nil, designCycles: nil, cyclesRemaining: nil)
        XCTAssertTrue(u.factors.allSatisfy { $0.level == .unknown })
    }
}
