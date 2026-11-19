import XCTest
@testable import FlightDeckCore

/// The robust fit, the forecast's refusals and its confidence range, on synthetic data with known answers.
final class BatteryForecastTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    /// Deterministic noise in [-1, 1).
    struct Rand { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) * 2 - 1 } }

    /// `n` daily points with health = start + perDay × day (+ noise), cycles at `cyclesPerDay`.
    func days(_ n: Int, start: Double = 95, perDay: Double, noise: Double = 0, step: Bool = false, cyclesPerDay: Double = 0.5, seed: UInt64 = 7) -> [BatteryDay] {
        var r = Rand(s: seed)
        return (0..<n).map { i in
            var h = start + perDay * Double(i) + noise * r.next()
            if step { h = h.rounded() }   // the gauge's Maximum Capacity is whole percent
            let d = t0.addingTimeInterval(Double(i) * 86_400)
            return BatteryDay(day: "d\(i)", start: d, health: h, cycles: Int(Double(i) * cyclesPerDay), source: .flightDeck)
        }
    }

    // MARK: Theil–Sen

    func testTheilSenExactLine() throws {
        let l = try XCTUnwrap(TheilSen.fit((0..<20).map { (x: Double($0), y: 3 - 0.5 * Double($0)) }))
        XCTAssertEqual(l.slope, -0.5, accuracy: 1e-12)
        XCTAssertEqual(l.intercept, 3, accuracy: 1e-12)
        XCTAssertEqual(l.y(10), -2, accuracy: 1e-12)
    }

    /// A quarter of the points are wild outliers (recalibration jumps); least squares would be dragged, Theil–Sen isn't.
    func testTheilSenIgnoresOutliers() throws {
        var pts = (0..<40).map { (x: Double($0), y: 100 - 0.05 * Double($0)) }
        for i in stride(from: 0, to: 40, by: 4) { pts[i].y += 8 }
        let l = try XCTUnwrap(TheilSen.fit(pts))
        XCTAssertEqual(l.slope, -0.05, accuracy: 0.01)
        // Ordinary least squares for comparison: the outliers on the early side bias it.
        let mx = pts.map(\.x).reduce(0, +) / 40, my = pts.map(\.y).reduce(0, +) / 40
        let ols = zip(pts.map(\.x), pts.map(\.y)).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / pts.map { ($0.x - mx) * ($0.x - mx) }.reduce(0, +)
        XCTAssertGreaterThan(abs(ols - -0.05), abs(l.slope - -0.05))
    }

    /// Readings stepped to whole percent: the fit still recovers the underlying slope, and the CI contains it.
    func testSteppedNoisyData() throws {
        let f = BatteryForecast.compute(days(180, start: 96, perDay: -0.015, noise: 0.8, step: true), designCycles: 1000, currentCycles: 90)
        XCTAssertEqual(f.status, .forecast)
        let py = try XCTUnwrap(f.perYear), range = try XCTUnwrap(f.perYearRange)
        XCTAssertEqual(py, -0.015 * 365, accuracy: 1.0)
        XCTAssertLessThan(range.low, -0.015 * 365); XCTAssertGreaterThan(range.high, -0.015 * 365)
    }

    func testTooFewPointsGivesNoInterval() throws {
        let l = try XCTUnwrap(TheilSen.fit([(0, 1), (1, 2), (2, 2.5)]))
        XCTAssertNil(l.slopeLow); XCTAssertNil(l.slopeHigh)
        XCTAssertNil(TheilSen.fit([(1, 1), (1, 2)]))   // no distinct x: no slope at all
    }

    // MARK: Refusals

    func testRefusesWithNoHistory() {
        let f = BatteryForecast.compute([], designCycles: nil, currentCycles: nil)
        guard case .insufficient = f.status else { return XCTFail("\(f.status)") }
        XCTAssertNil(f.date80)
    }

    func testRefusesUnderFourteenDaysAndSaysHowLong() {
        let f = BatteryForecast.compute(days(8, perDay: -0.5), designCycles: nil, currentCycles: nil)
        guard case let .insufficient(needed, weeks) = f.status else { return XCTFail("\(f.status)") }
        XCTAssertEqual(weeks, 1)   // 7 days of span, 7 more days needed
        XCTAssertTrue(needed.contains("1 more week"), needed)
        XCTAssertNil(f.date80); XCTAssertNil(f.line)
    }

    /// 30 days losing 0.02%/day = 0.6%: below the 2% change needed. At that pace 2% takes 100 days, 70 more.
    func testRefusesUnderTwoPercentChange() {
        let f = BatteryForecast.compute(days(31, perDay: -0.02), designCycles: nil, currentCycles: nil)
        guard case let .insufficient(needed, weeks) = f.status else { return XCTFail("\(f.status)") }
        XCTAssertEqual(weeks, 10)
        XCTAssertTrue(needed.contains("10 more weeks"), needed)
        XCTAssertNil(f.date80)
    }

    func testFlatHistoryCantEstimateWeeks() {
        let f = BatteryForecast.compute(days(60, perDay: 0, noise: 0.5, step: true), designCycles: nil, currentCycles: nil)
        guard case let .insufficient(needed, weeks) = f.status else { return XCTFail("\(f.status)") }
        XCTAssertNil(weeks)
        XCTAssertTrue(needed.contains("No measurable decline"), needed)
    }

    func testRisingHealthIsNotDeclining() {
        let f = BatteryForecast.compute(days(40, start: 88, perDay: 0.1), designCycles: nil, currentCycles: nil)
        guard case .notDeclining = f.status else { return XCTFail("\(f.status)") }
        XCTAssertNil(f.date80)
    }

    func testAlreadyBelowThreshold() {
        let f = BatteryForecast.compute(days(60, start: 82, perDay: -0.05), designCycles: nil, currentCycles: nil)
        XCTAssertEqual(f.status, .belowThreshold)
    }

    // MARK: The forecast and its range

    /// 95% → losing 0.02%/day for 200 days ends at 91%; 80% is 550 days after that. The range brackets the date.
    func testDateAndRange() throws {
        let hist = days(201, start: 95, perDay: -0.02, noise: 0.6)
        let f = BatteryForecast.compute(hist, designCycles: 1000, currentCycles: 100)
        XCTAssertEqual(f.status, .forecast)
        let d = try XCTUnwrap(f.date80), early = try XCTUnwrap(f.date80Early), late = try XCTUnwrap(f.date80Late)
        let expected = t0.addingTimeInterval(750 * 86_400)
        XCTAssertEqual(d.timeIntervalSince(expected) / 86_400, 0, accuracy: 60)
        XCTAssertLessThan(early, d); XCTAssertGreaterThan(late, d)
        // Band edges diverge away from the pivot and contain the trend.
        let b = try XCTUnwrap(f.band(at: expected))
        XCTAssertLessThan(b.low, b.mid); XCTAssertGreaterThan(b.high, b.mid)
        XCTAssertEqual(b.mid, 80, accuracy: 1.5)
    }

    /// More noise → a wider range; the same trend.
    func testRangeWidensWithNoise() throws {
        let quiet = BatteryForecast.compute(days(120, perDay: -0.03, noise: 0.2), designCycles: nil, currentCycles: nil)
        let loud = BatteryForecast.compute(days(120, perDay: -0.03, noise: 1.5), designCycles: nil, currentCycles: nil)
        let wq = try XCTUnwrap(quiet.perYearRange), wl = try XCTUnwrap(loud.perYearRange)
        XCTAssertGreaterThan(wl.high - wl.low, (wq.high - wq.low) * 2)
    }

    /// A slope range that includes "flat" leaves the late end unbounded rather than inventing a date.
    func testLateEndUnboundedWhenRangeIncludesFlat() {
        let f = BatteryForecast.compute(days(30, start: 96, perDay: -0.08, noise: 2.5, seed: 3), designCycles: nil, currentCycles: nil)
        guard f.status == .forecast, let hi = f.perYearRange?.high, hi >= 0 else { return }   // only meaningful for that draw
        XCTAssertNil(f.date80Late)
    }

    func testCyclesAndDesignCount() throws {
        let f = BatteryForecast.compute(days(201, perDay: -0.02, cyclesPerDay: 0.5), designCycles: 1000, currentCycles: 100)
        XCTAssertEqual(try XCTUnwrap(f.cyclesPerWeek), 3.5, accuracy: 0.2)
        XCTAssertEqual(f.cyclesRemaining, 900)
        // health = 95 − 0.04 × cycles → 80% at 375 cycles.
        XCTAssertEqual(Double(try XCTUnwrap(f.cycles80)), 375, accuracy: 10)
        let when = try XCTUnwrap(f.designCyclesDate)
        XCTAssertEqual(when.timeIntervalSince(t0.addingTimeInterval(200 * 86_400)) / 86_400, 900 / 0.5, accuracy: 60)
    }

    /// A replacement (cycles reset, health back near 100) starts the history over.
    func testReplacementStartsOver() {
        var hist = days(60, start: 85, perDay: -0.05, cyclesPerDay: 2)
        for i in 0..<30 {
            hist.append(BatteryDay(day: "n\(i)", start: t0.addingTimeInterval(Double(60 + i) * 86_400), health: 100, cycles: i, source: .flightDeck))
        }
        let f = BatteryForecast.compute(hist, designCycles: 1000, currentCycles: 29)
        XCTAssertEqual(f.points.count, 30)
        XCTAssertNotNil(f.replacedOn)
    }

    /// Long histories are thinned to weekly medians (bounded cost) and still fit.
    func testLongHistoryThinned() throws {
        let f = BatteryForecast.compute(days(1500, start: 100, perDay: -0.01, noise: 1), designCycles: nil, currentCycles: nil)
        XCTAssertEqual(f.status, .forecast)
        XCTAssertLessThanOrEqual(try XCTUnwrap(f.line).count, 215)
        XCTAssertEqual(try XCTUnwrap(f.perYear), -3.65, accuracy: 0.3)
    }
}
