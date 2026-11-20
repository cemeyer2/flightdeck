// The easter egg's pure parts: the Konami code matcher, building a course from history, and the flight physics.
import XCTest
@testable import FlightDeckCore

final class TurbulenceTests: XCTestCase {
    typealias X = MeasureFixtures

    func testKonamiCode() {
        var k = KonamiCode()
        XCTAssertFalse(KonamiCode.sequence.dropLast().contains { k.feed($0) })
        XCTAssertTrue(k.feed(.a), "the full sequence matches")
        // A wrong key restarts; an extra ↑ at the start still counts as the first two.
        var m = KonamiCode()
        for key in [KonamiCode.Key.up, .up, .down, .other] { _ = m.feed(key) }
        XCTAssertFalse(KonamiCode.sequence.dropLast().contains { m.feed($0) })
        XCTAssertTrue(m.feed(.a))
        var n = KonamiCode()
        _ = n.feed(.up)
        XCTAssertFalse(KonamiCode.sequence.dropLast().contains { n.feed($0) }, "↑ ↑ ↑ ↓ ↓ … still matches")
        XCTAssertTrue(n.feed(.a))
    }

    func testCourseFromHistory() {
        let busy = X.proc("Compiler", pid: 10, ppid: 1, start: X.t0, cpuTime: 1)
        var frames: [Snapshot] = []
        for i in 0..<60 {
            let cpu: Double = (25...35).contains(i) ? 95 : 10
            var p = busy
            p.cpu = cpu * 8
            frames.append(X.frame(X.t0.addingTimeInterval(Double(i) * 10), [p], cpu: cpu))
        }
        let c = TurbulenceCourse.from(frames.reversed())   // order doesn't matter
        XCTAssertEqual(c.columns.count, 60)
        XCTAssertEqual(c.secondsPerColumn, 10, accuracy: 0.001)
        XCTAssertEqual(c.columns.first?.time, X.t0, "oldest first")
        XCTAssertGreaterThan(c.columns[30].ground, c.columns[5].ground + 0.3, "busy CPU makes a mountain")
        XCTAssertEqual(c.columns.compactMap(\.label), ["Compiler"], "the peak is named once")
        for col in c.columns { XCTAssertLessThanOrEqual(col.ground + col.ceiling, 1 - TurbulenceCourse.minGap + 1e-9) }
    }

    func testCourseDownsamplesAndLoopsSmoothly() {
        var frames: [Snapshot] = []
        for i in 0..<1000 { frames.append(X.frame(X.t0.addingTimeInterval(Double(i)), [], cpu: Double(i % 100))) }
        let c = TurbulenceCourse.from(frames)
        XCTAssertLessThanOrEqual(c.columns.count, TurbulenceCourse.maxColumns)
        XCTAssertEqual(c.secondsPerColumn, 5, accuracy: 0.01, "1000 frames → 200 columns of 5 s")
        // Around the loop seam and the end of the runway, neighbouring positions never jump.
        let n = Double(c.columns.count + TurbulenceCourse.seam)
        for x in stride(from: -6.0, to: n * 2, by: 0.25) {
            // Never steeper than the plane can climb at top speed (a quarter column at a time).
            XCTAssertLessThanOrEqual(abs(c.at(x).ground - c.at(x + 0.25).ground), TurbulenceCourse.maxSlope / 4 + 0.03, "no cliff at \(x)")
            XCTAssertLessThanOrEqual(abs(c.at(x).ceiling - c.at(x + 0.25).ceiling), TurbulenceCourse.maxSlope / 4 + 0.03)
        }
        XCTAssertLessThanOrEqual(TurbulenceCourse.maxSlope * 11, TurbulenceGame.maxClimb, "climbable at top speed")
        XCTAssertNil(c.column(at: -1))
        XCTAssertEqual(c.column(at: n + 2)?.time, c.columns[2].time, "the course loops")
    }

    func testEmptyHistoryStillFlies() {
        let c = TurbulenceCourse.from([])
        XCTAssertEqual(c.secondsPerColumn, 0)
        XCTAssertFalse(c.columns.isEmpty)
    }

    func testFlightPhysics() {
        let course = TurbulenceCourse(columns: Array(repeating: .init(ground: 0.1, ceiling: 0.1), count: 50), secondsPerColumn: 10)
        var g = TurbulenceGame(course: course)
        g.step(0.05, climbing: true)
        XCTAssertEqual(g.phase, .ready, "nothing moves before takeoff")
        g.start()
        // Holding the whole time: rises into the ceiling.
        var t = 0.0
        while g.phase == .flying && t < 10 { g.step(1.0 / 60, climbing: true); t += 1.0 / 60 }
        XCTAssertEqual(g.phase, .crashed)
        XCTAssertGreaterThan(g.y, 0.8)
        // Restarting resets the flight; letting go the whole time sinks into the ground.
        g.start()
        XCTAssertEqual(g.phase, .flying)
        XCTAssertLessThan(g.distance, 0, "back on the runway")
        while g.phase == .flying { g.step(1.0 / 60, climbing: false) }
        XCTAssertLessThan(g.y, 0.2)
        // Pulsing keeps it airborne and scores course flown, in columns and in history seconds.
        var h = TurbulenceGame(course: course)
        h.start()
        var frame = 0
        while h.elapsed < 20 && h.phase == .flying {
            h.step(1.0 / 60, climbing: h.y < 0.45 && h.vy < 0.3); frame += 1
        }
        XCTAssertEqual(h.phase, .flying, "a steady hand survives 20 s of flat air")
        XCTAssertGreaterThan(h.score, 50)
        XCTAssertEqual(h.historyFlown, Double(h.score) * 10)
        // A long stall can't teleport the plane.
        var s = TurbulenceGame(course: course); s.start()
        let before = s.distance; s.step(5, climbing: false)
        XCTAssertLessThan(s.distance - before, 1)
    }
}
