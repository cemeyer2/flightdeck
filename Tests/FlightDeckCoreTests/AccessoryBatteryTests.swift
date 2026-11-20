import XCTest
@testable import FlightDeckCore

final class AccessoryBatteryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// A mouse charged to 100%, then losing `perDay` points a day, read every 30 minutes for `days`.
    func draining(from start: Int = 100, perDay: Double = 8, days: Double = 5, noise: Bool = true) -> [AccessoryReading] {
        stride(from: 0.0, through: days * 48, by: 1).map { i in
            let wobble = noise && Int(i) % 7 == 3 ? 1.0 : 0
            let v = Double(start) - perDay * i / 48 + wobble
            return AccessoryReading(time: t0.addingTimeInterval(i * 1800), levels: ["Main": Int(v.rounded())])
        }
    }

    func testEstimate() throws {
        let e = try XCTUnwrap(AccessoryForecast.estimate(draining()).value)
        XCTAssertEqual(e.ratePerDay, 8, accuracy: 0.5)
        XCTAssertEqual(e.daysLeft, 60.0 / 8, accuracy: 0.5)   // 100 − 5×8 = 60% left
        XCTAssertEqual(e.text, "about 8 days left at this rate")
    }

    func testEstimateUsesOnlyTheCurrentDischarge() throws {
        // An older discharge at a different rate, then a charge to 100%, then the current one.
        let old = draining(from: 90, perDay: 30, days: 2, noise: false).map { AccessoryReading(time: $0.time.addingTimeInterval(-4 * 86_400), levels: $0.levels) }
        let all = old + draining(perDay: 10, days: 2)
        let seg = AccessoryForecast.discharge(all, part: "Main")
        XCTAssertEqual(seg.first?.1, 100)
        let e = try XCTUnwrap(AccessoryForecast.estimate(all).value)
        XCTAssertEqual(e.ratePerDay, 10, accuracy: 0.6)
    }

    func testHoursText() {
        let e = AccessoryEstimate(ratePerDay: 48, daysLeft: 0.25, since: t0, readings: 5)
        XCTAssertEqual(e.text, "about 6 hours left at this rate")
    }

    func testUnavailableReasons() {
        XCTAssertNil(AccessoryForecast.estimate([]).value)
        let short = Array(draining().prefix(4))
        if case .unavailable(let why) = AccessoryForecast.estimate(short) { XCTAssertTrue(why.contains("a day")) } else { XCTFail() }
        let flat = (0..<50).map { AccessoryReading(time: t0.addingTimeInterval(Double($0) * 1800), levels: ["Main": 80]) }
        if case .unavailable(let why) = AccessoryForecast.estimate(flat) { XCTAssertTrue(why.contains("dropped")) } else { XCTFail() }
    }

    func testLowFindingOncePerDischarge() {
        let r = { (pct: Int) in AccessoryReading(time: self.t0, levels: ["Main": pct]) }
        XCTAssertNotNil(AccessoryForecast.lowFinding(name: "Mouse", previous: r(16), new: r(14)))
        XCTAssertNil(AccessoryForecast.lowFinding(name: "Mouse", previous: r(14), new: r(12)), "already below")
        XCTAssertNil(AccessoryForecast.lowFinding(name: "Mouse", previous: nil, new: r(40)))
        XCTAssertNil(AccessoryForecast.lowFinding(name: "Buds", previous: nil, new: AccessoryReading(time: t0, levels: ["Left": 5])), "buds don't warn")
    }

    func testStoreDedupesAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = AccessoryStore(dir: dir)
        XCTAssertTrue(s.record("Mouse", AccessoryReading(time: t0, levels: ["Main": 80])).kept)
        XCTAssertFalse(s.record("Mouse", AccessoryReading(time: t0.addingTimeInterval(1200), levels: ["Main": 80])).kept, "unchanged within 2 h")
        XCTAssertTrue(s.record("Mouse", AccessoryReading(time: t0.addingTimeInterval(2400), levels: ["Main": 79])).kept)
        XCTAssertTrue(s.record("Mouse", AccessoryReading(time: t0.addingTimeInterval(3 * 3600), levels: ["Main": 79])).kept, "unchanged but 2 h on")
        let again = AccessoryStore(dir: dir, readOnly: true)
        let h = again.history(since: t0.addingTimeInterval(-86_400), now: t0.addingTimeInterval(4 * 3600))
        XCTAssertEqual(h["Mouse"]?.map { $0.levels["Main"]! }, [80, 79, 79])
    }

    func testStoreSpansMonthsAndPrunes() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = AccessoryStore(dir: dir)
        let now = Date()
        for d in stride(from: 90, through: 0, by: -10) {
            s.record("Mouse", AccessoryReading(time: now.addingTimeInterval(-Double(d) * 86_400), levels: ["Main": 100 - d]))
        }
        s.prune(now: now)
        let h = AccessoryStore(dir: dir, readOnly: true).history(since: now.addingTimeInterval(-60 * 86_400), now: now)["Mouse"] ?? []
        XCTAssertEqual(h.count, 7, "60 days back to today, every 10 days")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertLessThanOrEqual(files.count, 4)
    }

    func testRecorderLowFinding() {
        let rec = AccessoryRecorder(store: AccessoryStore(preview: [:]))
        rec.record(["Mouse": ["Main": 20]], now: t0)
        XCTAssertTrue(rec.findings(now: t0).isEmpty)
        rec.record(["Mouse": ["Main": 14]], now: t0.addingTimeInterval(3600))
        XCTAssertEqual(rec.findings(now: t0.addingTimeInterval(3600)).map(\.id), ["accessory-low:Mouse"])
        rec.record(["Mouse": ["Main": 90]], now: t0.addingTimeInterval(7200))
        XCTAssertTrue(rec.findings(now: t0.addingTimeInterval(7200)).isEmpty, "charged")
    }

    func testCombine() {
        let history = ["Mouse": draining(), "Old Keyboard": [AccessoryReading(time: t0, levels: ["Main": 55])]]
        let list = AccessoryForecast.combine(current: [(name: "Mouse", kind: "Mouse", levels: ["Main": 60]),
                                                       (name: "Buds", kind: "Headphones", levels: ["Left": 70, "Right": 75, "Case": 40])],
                                             history: history, since: t0.addingTimeInterval(-86_400))
        XCTAssertEqual(list.map(\.name), ["Mouse", "Buds", "Old Keyboard"])
        XCTAssertNotNil(list[0].estimate.value)
        XCTAssertNil(list[1].estimate.value)
        XCTAssertEqual(list[1].orderedLevels.map(\.part), ["Left", "Right", "Case"])
        XCTAssertFalse(list[2].connected)
        XCTAssertEqual(AccessoryForecast.sparkValues([AccessoryReading(time: t0, levels: ["Left": 70, "Right": 60])]).first?.1, 60)
    }

    func testMCPOutput() throws {
        let link = USBLinks.analyze([USBLinkInput(id: 1, parent: nil, props: PeripheralFixtures.ssdAtUSB2, interfaceClasses: [8],
                                                  port: USBPortInfo(props: PeripheralFixtures.hsPort, name: "p"))])
        let acc = AccessoryForecast.combine(current: [(name: "Mouse", kind: nil, levels: ["Main": 12])], history: ["Mouse": draining(from: 52)], since: t0)
        let j = MCPTools.peripheralsJSON(links: LinkReport(usb: link), accessories: acc, now: t0)
        let s = try XCTUnwrap(j["summary"]?.string)
        XCTAssertTrue(s.contains("1 linked slower"), s)
        XCTAssertTrue(s.contains("Mouse is at 12%"), s)
        XCTAssertEqual(j["usb"]?.array?.first?["status"]?.string, "slow")
        XCTAssertEqual(j["usb"]?.array?.first?["device_support_inferred"]?.bool, true)
        XCTAssertEqual(j["accessory_batteries"]?.array?.first?["main_pct"]?.int, 12)
    }
}
