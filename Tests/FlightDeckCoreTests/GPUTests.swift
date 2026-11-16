// GPU sampler smoke test against the real GPU (IOAccelerator statistics plus IOReport on Apple silicon). It prints
// every reading for manual review and asserts only invariants that must hold on any Mac with a GPU.
import XCTest
@testable import FlightDeckCore

final class GPUTests: XCTestCase {
    /// After a warm-up sample: device utilisation is measured, the clock lies within the GPU's own DVFS range, the
    /// per-state residencies add up to the active residency (so the P-state chart is consistent), and per-client
    /// GPU shares are real percentages. Needs a real GPU with at least one client (e.g. WindowServer).
    func testGPUSample() throws {
        let g = GPUSampler()
        _ = g.sample(); Thread.sleep(forTimeInterval: 1)
        let d = g.sample()
        // VMs and headless CI machines expose no accelerator statistics: that's "unavailable", not a failure.
        guard d.deviceUtilization != nil else { throw XCTSkip("no GPU statistics on this machine") }
        print("GPU util", d.deviceUtilization as Any, "active", d.activeResidency as Any, "MHz", d.frequencyMHz as Any, "W", d.powerWatts as Any,
              "cltm", d.thermalLimited as Any, "mem", d.memoryInUse as Any, "recov", d.recoveryCount as Any)
        print("GPU states", d.stateResidency?.map { Int($0) } as Any, d.stateMHz as Any)
        print("GPU clients", d.clients.prefix(5).map { "\($0.name) \(String(format: "%.1f", $0.percent))%" })
        print("CPU clusters", d.cpuClusters.map { "\($0.name) \($0.mhz.map { Int($0) } ?? -1) MHz \(Int($0.active))%" }, "cpuW", d.cpuPowerWatts as Any, "ane", d.anePowerWatts as Any)
        print("INFO", GPUSampler.info().model, GPUSampler.info().cores as Any)
        XCTAssertNotNil(d.deviceUtilization)
        if let f = d.frequencyMHz, let r = GPUSampler.info().frequencyRange { XCTAssert(f >= r.min - 1 && f <= r.max + 1) }
        if let s = d.stateResidency, let a = d.activeResidency { XCTAssertEqual(s.reduce(0, +), a, accuracy: 0.5) }
        XCTAssertFalse(d.clients.isEmpty)
        XCTAssertTrue(d.clients.allSatisfy { (0...100).contains($0.percent) })
    }
}
