import XCTest
@testable import FlightdeckCore

final class BlackBoxTests: XCTestCase {
    static let base: Snapshot = { let s = Sampler(); _ = s.sample(); return s.sample() }()
    func frame(_ t: Date) -> Snapshot { var s = Self.base; s.time = t; return s }

    func makeBox(_ cfg: (inout BlackBox.Config) -> Void = { _ in }) -> BlackBox {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bb-\(UUID().uuidString)")
        var c = BlackBox.Config(); cfg(&c)
        return BlackBox(dir: dir, config: c)
    }

    func testTiersSegmentsAndRetrieval() {
        let box = makeBox()
        let t0 = Date().addingTimeInterval(-300)
        for i in 0..<250 { box.append(frame(t0.addingTimeInterval(Double(i))), interval: 1) }   // 250 s at 1 Hz
        let segs = box.segments()
        XCTAssertEqual(segs.filter { $0.tier == .fine }.count, 4, "one fine segment per 60 s, rest pending")
        XCTAssertEqual(segs.filter { $0.tier == .coarse }.count, 0, "coarse segments are 10 min long")
        let fine = box.trace(.fine, from: t0)!
        XCTAssertEqual(fine.frames.count, 250, "flushed + pending frames")
        XCTAssertEqual(fine.interval, 1)
        let coarse = box.trace(.coarse, from: t0)!
        XCTAssertEqual(coarse.frames.count, 25, "one frame per 10 s")
        XCTAssertEqual(coarse.interval, 10)
        XCTAssertLessThanOrEqual(fine.frames[0].processes.count, box.config.keepProcesses + box.config.keepProcesses / 5)
        let window = box.trace(.fine, from: t0.addingTimeInterval(100), to: t0.addingTimeInterval(159))!
        XCTAssertEqual(window.frames.count, 60)
        box.flush()
        XCTAssertEqual(box.trace(.fine, from: t0)!.frames.count, 250, "flush must not duplicate or lose frames")
    }

    func testGapIsPreserved() {
        let box = makeBox()
        let t0 = Date().addingTimeInterval(-200)
        for i in 0..<30 { box.append(frame(t0.addingTimeInterval(Double(i))), interval: 1) }
        for i in 90..<120 { box.append(frame(t0.addingTimeInterval(Double(i))), interval: 1) }   // paused 60 s
        let f = box.trace(.fine, from: t0)!.frames
        XCTAssertEqual(f.count, 60, "no frames are invented for the gap")
        XCTAssertEqual(f[30].time.timeIntervalSince(f[29].time), 61, accuracy: 0.001)
    }

    func testRetentionAndSizeCap() {
        let box = makeBox { $0.fineRetention = 120; $0.coarseRetention = 100_000 }
        let now = Date()
        let t0 = now.addingTimeInterval(-600)
        for i in 0..<600 { box.append(frame(t0.addingTimeInterval(Double(i))), interval: 1) }
        box.prune(now: now)
        let fine = box.segments().filter { $0.tier == .fine }
        XCTAssertFalse(fine.isEmpty)
        XCTAssertTrue(fine.allSatisfy { now.timeIntervalSince($0.end) <= 120 }, "fine tier keeps only its retention window")

        let capped = makeBox { $0.maxBytes = 1 }
        for i in 0..<130 { capped.append(frame(t0.addingTimeInterval(Double(i))), interval: 1) }
        XCTAssertTrue(capped.segments().isEmpty, "size cap deletes oldest segments")
        capped.clear()
        XCTAssertNil(capped.trace(.fine, from: t0))
    }
}
