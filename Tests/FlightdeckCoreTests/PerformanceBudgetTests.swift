import XCTest
@testable import FlightdeckCore
/// Prints what each source costs and guards Flightdeck's own sampling overhead.
final class PerformanceBudgetTests: XCTestCase {
    func testCost() {
        func time(_ n: String, _ k: Int = 5, _ f: () -> Void) { let t = Date(); for _ in 0..<k { f() }; print("COST", n, String(format: "%.1f ms", Date().timeIntervalSince(t) / Double(k) * 1000)) }
        let ps = ProcessSampler(); _ = ps.sample()
        time("processes") { _ = ps.sample() }
        let pn = ProcessNetworkSampler(); _ = pn.sample()
        time("nettop", 2) { _ = pn.sample() }
        time("hangs") { _ = HangDetector.check() }
        time("assertions") { _ = PowerAssertions.byPID() }
        let g = GPUSampler(); _ = g.sample()
        time("gpu") { _ = g.sample() }
        time("wifi") { _ = WiFiInfo.current() }
        let pw = PowerSampler(); time("power") { _ = pw.sample() }
        let d = DiskSampler(); time("disk") { _ = d.sample() }
        let n = NetworkSampler(); time("net") { _ = n.sample() }
        let c = CPUSampler(); time("cpu") { _ = c.sample() }
        let m = MemorySampler(); time("mem") { _ = m.sample() }
        time("gpuUtil") { _ = SystemInfo.gpuUtilization() }
        let s = Sampler(); _ = s.sample()
        time("TOTAL", 3) { _ = s.sample() }
        func cpu() -> Double { var r = rusage(); getrusage(RUSAGE_SELF, &r); return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6 }
        let c0 = cpu(); for _ in 0..<10 { _ = s.sample() }; let perSample = (cpu() - c0) * 100
        print("COST in-process CPU per sample", String(format: "%.1f ms", perSample))
        XCTAssertLessThan(perSample, 100, "sampling must stay cheap (ms of CPU per sample, debug build)")
        let a = Analyzer(); let snap = s.sample()
        time("analyzer") { _ = a.ingest(snap) }
        time("encode") { _ = try? JSONEncoder().encode(Trace.trimmed(snap)) }
    }
}
