import XCTest
@testable import FlightDeckCore
import FlightDeckHelperProtocol

final class HelperMergeTests: XCTestCase {
    let helperValues = HelperRusage(cpuNs: 999, diskRead: 50, diskWritten: 60, energyNJ: 70, idleWakeups: 80, physFootprint: 90, threads: 12)

    func raw(cpu: UInt64, ruOK: Bool) -> RawCounters {
        RawCounters(cpuNs: cpu, r: ruOK ? 1 : 0, w: ruOK ? 2 : 0, energy: ruOK ? 3 : 0, wake: ruOK ? 4 : 0,
                    footprint: ruOK ? 5 : 0, threads: 0, ruOK: ruOK)
    }

    func testMergeNeverOverwritesAppValues() {
        let (m, source) = ProcessSampler.merge(app: raw(cpu: 100, ruOK: true), taskRefused: true, helper: helperValues)
        XCTAssertEqual(m.cpuNs, 100)
        XCTAssertEqual(m.r, 1)
        XCTAssertEqual(m.footprint, 5)
        XCTAssertEqual(m.threads, 12)
        XCTAssertEqual(source, .app)
    }

    func testMergeFillsRefused() {
        let (m, source) = ProcessSampler.merge(app: raw(cpu: 0, ruOK: false), taskRefused: true, helper: helperValues)
        XCTAssertEqual(m, RawCounters(cpuNs: 999, r: 50, w: 60, energy: 70, wake: 80, footprint: 90, threads: 12, ruOK: true))
        XCTAssertEqual(source, .helper)
    }

    func testMergeWithoutHelper() {
        let app = raw(cpu: 0, ruOK: false)
        let (m, source) = ProcessSampler.merge(app: app, taskRefused: true, helper: nil)
        XCTAssertEqual(m, app)
        XCTAssertEqual(source, .app)
        // A process the app read fully is never touched, even if the helper had values.
        let own = raw(cpu: 7, ruOK: true)
        XCTAssertEqual(ProcessSampler.merge(app: own, taskRefused: false, helper: helperValues).0, own)
    }

    func testSourceChangeRestartsRate() {
        let p = ProcessSampler.Prev(cpuNs: 1, r: 1, w: 1, energy: 1, wake: 1, source: .app)
        XCTAssertNil(ProcessSampler.rateBasis(p, source: .helper))
        XCTAssertNotNil(ProcessSampler.rateBasis(p, source: .app))
        XCTAssertNil(ProcessSampler.rateBasis(nil, source: .app))
        let h = ProcessSampler.Prev(cpuNs: 1, r: 1, w: 1, energy: 1, wake: 1, source: .helper)
        XCTAssertNil(ProcessSampler.rateBasis(h, source: .app))
    }

    final class Provider: HelperRusageProviding {
        var values: HelperRusage?
        var asked: [[ProcessIdentity]] = []
        init(_ v: HelperRusage?) { values = v }
        func rusage(for ids: [ProcessIdentity]) -> [ProcessIdentity: HelperRusage]? {
            asked.append(ids)
            guard let values else { return nil }
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, values) })
        }
    }

    func testNilHelperResultKeepsAppValues() {
        let sampler = ProcessSampler()
        let provider = Provider(nil)
        sampler.helper = provider
        for _ in 0..<2 {
            XCTAssertFalse(sampler.sample().contains { $0.source == .helper })
        }
    }

    func testHelperFillsOnlyRefusedProcesses() {
        let sampler = ProcessSampler()
        let provider = Provider(helperValues)
        sampler.helper = provider
        let procs = sampler.sample()
        let asked = Set(provider.asked.flatMap { $0 })
        for p in procs where p.source == .helper {
            XCTAssertTrue(asked.contains(p.identity))
            XCTAssertTrue(p.restricted)
            XCTAssertEqual(p.memory, 90)
        }
        // Our own process is always read by the app itself.
        let me = procs.first { $0.pid == getpid() }
        XCTAssertNotNil(me)
        XCTAssertNil(me?.source)
        XCTAssertFalse(asked.contains { $0.pid == getpid() })
        // The second sample sees no spike for helper-filled rows: same source, same counters, so 0 %.
        for p in sampler.sample() where p.source == .helper { XCTAssertEqual(p.cpu, 0, accuracy: 0.001) }
    }

    func testOldTraceDecodesWithoutSource() throws {
        var p = BlackBoxTests.base.processes[0]
        p.source = .helper
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        XCTAssertEqual(obj["source"] as? String, "helper")
        obj["source"] = nil
        let old = try JSONDecoder().decode(ProcessSample.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(old.source)
        XCTAssertTrue(old.isAppMeasured)
    }

    func testUnreadableIgnoresHelperFilled() {
        var p = BlackBoxTests.base.processes[0]
        p.restricted = true; p.cpuTime = 0; p.memory = 0
        XCTAssertTrue(MCPTools.unreadable(p))
        XCTAssertNil(MCPTools.memory(p))
        XCTAssertTrue(p.valuesUnreadable)
        p.source = .helper
        XCTAssertFalse(MCPTools.unreadable(p))
        XCTAssertNotNil(MCPTools.memory(p))
        XCTAssertFalse(p.valuesUnreadable)
    }
}
