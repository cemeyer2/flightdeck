// Tests for charging insights: AppleSmartBattery parsing (USB-PD menu, port-controller PDOs, missing keys), the power
// flow math and its signs, time-to-80%/100% estimates, hold detection and pmset parsing, and the in-memory charge curve.
// Fixtures are in ChargingFixtures.swift. The one live test skips on Macs without a battery (CI VMs).
import XCTest
import IOKit
@testable import FlightDeckCore

final class ChargingTests: XCTestCase {
    /// BatteryInfo the way PowerSampler builds it (mV, mA reinterpreted as signed, capacity ratio).
    func battery(_ d: [String: Any]) -> BatteryInfo {
        let cur = ASB.int(d["CurrentCapacity"]) ?? 0, mx = ASB.int(d["MaxCapacity"]) ?? 100
        return BatteryInfo(percent: Double(cur) / Double(mx) * 100, isCharging: ASB.bool(d["IsCharging"]) ?? false,
                           externalConnected: ASB.bool(d["ExternalConnected"]) ?? false,
                           voltage: ASB.int(d["Voltage"]).map { Double($0) / 1000 },
                           amperage: ASB.signed(d["InstantAmperage"] ?? d["Amperage"]).map { Double($0) / 1000 })
    }

    // MARK: Parsing

    func testUsbHvcMenuDecoding() throws {
        let c = ChargingDetails.parse(ChargingFixtures.appleSiliconCharging)
        let a = try XCTUnwrap(c.adapter)
        XCTAssertEqual(a.offers.map(\.volts), [5, 9, 15, 20])
        XCTAssertEqual(a.offers.map(\.amps), [3, 3, 3, 4.7])
        XCTAssertEqual(a.offersSource, .usbHvcMenu)
        XCTAssertEqual(a.activeOffer?.volts, 20)
        XCTAssertEqual(try XCTUnwrap(a.negotiatedWatts), 94, accuracy: 0.001)
        XCTAssertEqual(a.watts, 96); XCTAssertEqual(a.name, "96W USB-C Power Adapter"); XCTAssertEqual(a.isWireless, false)
        XCTAssertEqual(a.familyName, "USB-C Power Delivery")
        XCTAssertEqual(a.port, 1); XCTAssertEqual(a.portCount, 3)
        XCTAssertEqual(c.avgTimeToFull, 52)
        XCTAssertEqual(c.facts.cellVoltages, [4.16, 4.158, 4.162])
        XCTAssertEqual(c.facts.fullChargeCapacity, 5702); XCTAssertEqual(c.facts.designCapacity, 6249)
    }

    func testTopLevelMenuAndManufactureDate() throws {
        let c = ChargingDetails.parse(ChargingFixtures.intelCharging)
        let a = try XCTUnwrap(c.adapter)
        XCTAssertEqual(a.offers.map(\.volts), [5, 9, 20])
        XCTAssertEqual(a.activeOffer?.amps, 3.05)
        XCTAssertNil(c.telemetry)
        XCTAssertNil(c.avgTimeToFull, "65535 means not calculated")
        XCTAssertEqual(c.facts.manufactureDate, "2020-02-15")
        XCTAssertNil(ChargingDetails.decodeManufactureDate(0))
    }

    /// This Mac on battery: no adapter (the stale port contract is ignored), telemetry signs kept, no menu.
    func testThisMacOnBatteryFixture() {
        for d in [ChargingFixtures.thisMacOnBattery, ChargingFixtures.thisMacUnsignedAmperage] {
            let c = ChargingDetails.parse(d)
            XCTAssertNil(c.adapter)
            XCTAssertEqual(c.telemetry?.batteryPower ?? 0, -16.215, accuracy: 1e-9)
            XCTAssertEqual(c.telemetry?.systemLoad ?? 0, 16.215, accuracy: 1e-9)
            XCTAssertEqual(c.telemetry?.systemPowerIn, 0)
            XCTAssertEqual(c.charger?.notChargingReason, 4194433)
            XCTAssertEqual(c.facts.designCycles, 1000); XCTAssertEqual(c.facts.nominalCapacity, 7475)
            XCTAssertEqual(c.facts.fullyCharged, true); XCTAssertTrue(c.facts.cellVoltages.isEmpty)
            XCTAssertNil(c.facts.manufactureDate)
            XCTAssertEqual(battery(d).amperage ?? 0, -1.308, accuracy: 1e-9)
        }
    }

    /// The stale contract in this Mac's fixture decodes to the 140 W charger it last used: 5/9/15/20/28 V and EPR AVS.
    func testPortControllerPDODecoding() throws {
        let ports = ChargingFixtures.thisMacOnBattery["PortControllerInfo"] as! [[String: Any]]
        let pc = try XCTUnwrap(ChargingDetails.portContract(ports))
        XCTAssertEqual(pc.port, 3)
        XCTAssertEqual(pc.offers.filter { $0.kind == .fixed }.map(\.volts), [5, 9, 15, 20, 28])
        XCTAssertEqual(pc.offers[0].amps ?? 0, 2.96, accuracy: 1e-9); XCTAssertEqual(pc.offers[3].amps ?? 0, 4.99, accuracy: 1e-9)
        let avs = try XCTUnwrap(pc.offers.first { $0.kind == .avs })
        XCTAssertEqual(avs.volts, 28, accuracy: 1e-9); XCTAssertEqual(avs.minVolts ?? 0, 15, accuracy: 1e-9); XCTAssertEqual(avs.maxWatts, 139)
        XCTAssertEqual(pc.position, 1)
        XCTAssertNil(ChargingDetails.decodePDO(0, position: 1))
        // PPS: 3.3-11 V at 3 A = 0b1100 | max 110 (×100 mV) << 17 | min 33 << 8 | 60 (×50 mA).
        let pps = try XCTUnwrap(ChargingDetails.decodePDO(0xC000_0000 | 110 << 17 | 33 << 8 | 60, position: 5))
        XCTAssertEqual(pps.kind, .pps); XCTAssertEqual(pps.volts, 11, accuracy: 1e-9); XCTAssertEqual(pps.amps ?? 0, 3, accuracy: 1e-9)
    }

    /// Two live contracts: which one powers the Mac is unknowable, so no port is claimed.
    func testAmbiguousPortContract() {
        let p: [String: Any] = ["PortControllerActiveContractRdo": 1 << 28, "PortControllerNPDOs": 1, "PortControllerPortPDO": [142709032] as [Any]]
        XCTAssertNil(ChargingDetails.portContract([p, p]))
    }

    func testMissingKeys() {
        let c = ChargingDetails.parse([:])
        XCTAssertNil(c.adapter); XCTAssertNil(c.telemetry); XCTAssertNil(c.charger); XCTAssertNil(c.avgTimeToFull)
        XCTAssertNil(c.facts.designCapacity); XCTAssertNil(c.facts.fullChargeCapacity); XCTAssertNil(c.facts.fullyCharged)
        // Connected but the adapter reports nothing: no adapter, not an empty one.
        XCTAssertNil(ChargingDetails.parse(["ExternalConnected": true, "AdapterDetails": ["FamilyCode": 0] as [String: Any]]).adapter)
        // A menu entry without a voltage is skipped.
        XCTAssertEqual(ChargingDetails.decodeMenu([["Index": 0, "MaxCurrent": 3000] as [String: Any], "junk"]).count, 0)
        XCTAssertNil(ChargeFlow.compute(battery: nil, telemetry: nil))
    }

    // MARK: Flow

    func testFlowWhileCharging() throws {
        let d = ChargingFixtures.appleSiliconCharging
        let f = try XCTUnwrap(ChargeFlow.compute(battery: battery(d), telemetry: ChargingDetails.parse(d).telemetry))
        XCTAssertEqual(f.source, .adapter)
        XCTAssertEqual(try XCTUnwrap(f.battery), 12.48 * 3.92, accuracy: 1e-9)   // V × A, positive while charging
        XCTAssertEqual(try XCTUnwrap(f.adapterToBattery), 12.48 * 3.92, accuracy: 1e-9)
        XCTAssertEqual(f.adapterIn, 76.4); XCTAssertEqual(f.mac, 22.1); XCTAssertEqual(f.loss, 5.2)
        XCTAssertEqual(f.adapterToMac, 22.1); XCTAssertEqual(f.batteryToMac, 0)
    }

    func testFlowOnBatteryAndShortfall() throws {
        let d = ChargingFixtures.thisMacUnsignedAmperage
        let f = try XCTUnwrap(ChargeFlow.compute(battery: battery(d), telemetry: ChargingDetails.parse(d).telemetry))
        XCTAssertEqual(f.source, .battery)
        XCTAssertLessThan(f.battery ?? 0, 0)
        XCTAssertEqual(try XCTUnwrap(f.batteryToMac), 12.397 * 1.308, accuracy: 1e-9)
        XCTAssertNil(f.adapterToMac); XCTAssertNil(f.adapterToBattery); XCTAssertNil(f.adapterIn, "SystemPowerIn 0 is not a reading")
        // No telemetry: the Mac's draw on battery is the discharge power.
        let g = try XCTUnwrap(ChargeFlow.compute(battery: battery(d), telemetry: nil))
        XCTAssertEqual(try XCTUnwrap(g.mac), 12.397 * 1.308, accuracy: 1e-9)
        // Plugged in but draining (charger too weak): battery tops up the Mac, adapter covers the rest.
        var b = battery(d); b.externalConnected = true
        let h = try XCTUnwrap(ChargeFlow.compute(battery: b, telemetry: PowerTelemetry(systemPowerIn: 30, systemLoad: 45)))
        XCTAssertEqual(try XCTUnwrap(h.batteryToMac), 16.215, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(h.adapterToMac), 45 - 12.397 * 1.308, accuracy: 1e-9)
        XCTAssertFalse(ChargerCheck.warnings(adapter: nil, flow: h, charger: nil, peakSystemW: nil).isEmpty)
        // Derived Mac draw from adapter input when SystemLoad is absent.
        var c = battery(ChargingFixtures.appleSiliconCharging); c.amperage = 2
        let k = try XCTUnwrap(ChargeFlow.compute(battery: c, telemetry: PowerTelemetry(systemPowerIn: 60, adapterEfficiencyLoss: 4)))
        XCTAssertEqual(try XCTUnwrap(k.mac), 60 - 12.48 * 2 - 4, accuracy: 1e-9)
    }

    func testWeakChargerWarnings() {
        let a = AdapterReport(watts: 30)
        XCTAssertEqual(ChargerCheck.warnings(adapter: a, flow: nil, charger: nil, peakSystemW: 45).count, 1)
        XCTAssertTrue(ChargerCheck.warnings(adapter: a, flow: nil, charger: nil, peakSystemW: 20).isEmpty)
        XCTAssertEqual(ChargerCheck.warnings(adapter: nil, flow: nil, charger: ChargerFlags(slowChargingReason: 2), peakSystemW: nil).count, 1)
    }

    // MARK: Estimates

    func testRateAndEstimates() throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let pts = (0...10).map { (time: t0.addingTimeInterval(Double($0) * 60), percent: 50 + Double($0)) }   // 1 %/min
        let r = try XCTUnwrap(ChargeEstimate.rate(pts, now: t0.addingTimeInterval(600)))
        XCTAssertEqual(r, 1, accuracy: 1e-9)
        XCTAssertNil(ChargeEstimate.rate(Array(pts.prefix(2)), now: t0.addingTimeInterval(60)), "too few points")
        XCTAssertNil(ChargeEstimate.rate(pts.map { ($0.time, 60) }, now: t0.addingTimeInterval(600)), "flat")

        // macOS gives time to full; time to 80% comes from the rate.
        let e = try XCTUnwrap(ChargeEstimate.estimate(percent: 60, isCharging: true, fullyCharged: false, avgTimeToFull: 52, timeRemaining: nil, ratePerMinute: 1))
        XCTAssertEqual(e.to80, ChargeETA(minutes: 20, basis: .recentRate))
        XCTAssertEqual(e.toFull, ChargeETA(minutes: 52, basis: .macOS))
        // No macOS estimate: rate for both.
        let f = try XCTUnwrap(ChargeEstimate.estimate(percent: 90, isCharging: true, fullyCharged: nil, avgTimeToFull: nil, timeRemaining: nil, ratePerMinute: 0.5))
        XCTAssertEqual(f.to80.basis, .reached); XCTAssertEqual(f.toFull, ChargeETA(minutes: 20, basis: .recentRate))
        // Unknown rate: the basis is still stated, minutes nil.
        let g = try XCTUnwrap(ChargeEstimate.estimate(percent: 30, isCharging: true, fullyCharged: nil, avgTimeToFull: nil, timeRemaining: nil, ratePerMinute: nil))
        XCTAssertNil(g.to80.minutes); XCTAssertNil(g.toFull.minutes)
        XCTAssertNil(ChargeEstimate.estimate(percent: 50, isCharging: false, fullyCharged: false, avgTimeToFull: nil, timeRemaining: 200, ratePerMinute: nil))
        XCTAssertEqual(ChargeEstimate.estimate(percent: 100, isCharging: false, fullyCharged: true, avgTimeToFull: nil, timeRemaining: nil, ratePerMinute: nil)?.toFull.basis, .reached)
    }

    // MARK: Holds

    func testPmsetParsing() throws {
        let held = try XCTUnwrap(PmsetBattery.parse("Now drawing from 'AC Power'\n -InternalBattery-0 (id=8978531)\t80%; AC attached; not charging present: true\n"))
        XCTAssertEqual(held.source, "AC Power"); XCTAssertEqual(held.percent, 80); XCTAssertEqual(held.state, "AC attached"); XCTAssertTrue(held.notCharging)
        let onBat = try XCTUnwrap(PmsetBattery.parse("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=8978531)\t100%; discharging; 8:33 remaining present: true"))
        XCTAssertEqual(onBat.state, "discharging"); XCTAssertFalse(onBat.notCharging); XCTAssertFalse(onBat.onHold)
        XCTAssertTrue(PmsetBattery.parse(" -InternalBattery-0 (id=1)\t79%; AC attached; charging on hold present: true")?.onHold ?? false)
        XCTAssertNil(PmsetBattery.parse(""))
    }

    func testHoldDetection() {
        var b = battery(ChargingFixtures.appleSiliconCharging)
        XCTAssertEqual(ChargeState.assess(battery: nil, details: nil, pmset: nil), .noBattery)
        XCTAssertEqual(ChargeState.assess(battery: b, details: nil, pmset: nil), .charging)
        b.isCharging = false; b.percent = 80
        let pm = PmsetBattery.parse(" -InternalBattery-0 (id=1)\t80%; AC attached; not charging present: true")
        let d = ChargingDetails.parse(["ChargerData": ["NotChargingReason": 0x400] as [String: Any]])
        XCTAssertEqual(ChargeState.assess(battery: b, details: d, pmset: pm), .held(percent: 80, pmsetConfirms: true, reasonCode: 0x400))
        XCTAssertEqual(ChargeState.assess(battery: b, details: nil, pmset: nil), .held(percent: 80, pmsetConfirms: false, reasonCode: nil))
        b.percent = 100
        XCTAssertEqual(ChargeState.assess(battery: b, details: nil, pmset: nil), .full)
        b.externalConnected = false
        XCTAssertEqual(ChargeState.assess(battery: b, details: nil, pmset: nil), .onBattery)
    }

    // MARK: Curve

    func testChargeCurveSessions() throws {
        let curve = ChargeCurve(spacing: 10, maxPoints: 4)
        var s = BlackBoxTests.base
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        s.power.battery = battery(ChargingFixtures.appleSiliconCharging)
        for i in 0..<6 { s.time = t0.addingTimeInterval(Double(i) * 10); s.power.battery?.percent = 50 + Double(i); curve.ingest(s) }
        var st = try XCTUnwrap(curve.state.session)
        XCTAssertLessThanOrEqual(st.points.count, 4, "thinned"); XCTAssertNil(st.end)
        s.power.battery?.externalConnected = false; s.time = t0.addingTimeInterval(70); curve.ingest(s)
        st = try XCTUnwrap(curve.state.session); XCTAssertEqual(st.end, s.time)
        let b = st.buckets(7, now: s.time) { $0.percent }
        XCTAssertEqual(b.count, 7); XCTAssertEqual(b.first ?? nil, 50)
        s.power.battery?.externalConnected = true; s.time = t0.addingTimeInterval(100); curve.ingest(s)
        XCTAssertEqual(curve.state.session?.points.count, 1, "a new plug-in starts a new session")
        s.power.battery = nil; curve.ingest(s)
        XCTAssertNil(curve.state.session)
    }

    /// Live: this Mac's AppleSmartBattery parses without crashing and agrees with itself. Skipped without a battery.
    func testLiveBattery() throws {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { throw XCTSkip("no battery (desktop Mac or CI VM)") }
        IOObjectRelease(svc)
        let p = PowerSampler().sample()
        let c = try XCTUnwrap(p.charging)
        if p.battery?.externalConnected == false { XCTAssertNil(c.adapter) }
        if let a = c.adapter, let i = a.activeOfferIndex, !a.offers.isEmpty { XCTAssertNotNil(a.offers.first { $0.index == i }) }
    }
}

/// Apple's 140 W charger in USB-PD 3.1 EPR mode, as captured live: UsbHvcMenu stops at 20 V and its index points past
/// it; the port controller lists the 28 V offers but its contract names the 20 V one. The 28 V the adapter reports wins.
final class ChargingEPRTests: XCTestCase {
    func testEPRContractPicksTheOfferMatchingTheAdapterVoltage() {
        // PDOs: fixed 5 V 2.96 A, 9 V 2.97 A, 15 V 2.98 A, 20 V 4.99 A (positions 1–4), then EPR fixed 28 V 4.99 A at 8.
        func fixed(_ v: Double, _ a: Double) -> Int { (Int(v * 20) << 10) | Int(a * 100) }
        let pdos: [Int] = [fixed(5, 2.96), fixed(9, 2.97), fixed(15, 2.98), fixed(20, 4.99), 0, 0, 0, fixed(28, 4.99)]
        let menu: [[String: Any]] = [[ "Index": 0, "MaxVoltage": 5000, "MaxCurrent": 2960 ], [ "Index": 1, "MaxVoltage": 9000, "MaxCurrent": 2970 ],
                                     [ "Index": 2, "MaxVoltage": 15000, "MaxCurrent": 2980 ], [ "Index": 3, "MaxVoltage": 20000, "MaxCurrent": 4990 ]]
        let d: [String: Any] = [
            "ExternalConnected": true,
            "AdapterDetails": ["Watts": 140, "AdapterVoltage": 28000, "Current": 4990, "Name": "140W USB-C Power Adapter",
                               "UsbHvcMenu": menu, "UsbHvcHvcIndex": 7],
            "PortControllerInfo": [["PortControllerActiveContractRdo": 4 << 28 | 0x1F3, "PortControllerNPDOs": pdos.count, "PortControllerPortPDO": pdos]],
        ]
        let a = ChargingDetails.parse(d).adapter
        XCTAssertEqual(a?.offersSource, .portController)
        XCTAssertEqual(a?.activeOffer?.volts ?? 0, 28, accuracy: 0.01)
        XCTAssertEqual(a?.adapterVolts ?? 0, 28, accuracy: 0.01)
    }
}
