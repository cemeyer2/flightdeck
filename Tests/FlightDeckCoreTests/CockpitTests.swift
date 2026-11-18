// Tests for the customizable cockpit model (Cockpit.swift, CockpitStore.swift): the instrument catalogue, the default
// layout matching the classic Summary page, JSON round-trips and lenient decoding, first-run migration, editing,
// grid packing, Ambient gauge selection and the burn-in shift.
import XCTest
@testable import FlightDeckCore

final class CockpitTests: XCTestCase {
    func testInstrumentCatalogueIsComplete() {
        // Raw values are the stored form and titles are shown in the palette: both must be unique.
        XCTAssertEqual(Set(InstrumentKind.allCases.map(\.rawValue)).count, InstrumentKind.allCases.count)
        XCTAssertEqual(Set(InstrumentKind.allCases.map(\.title)).count, InstrumentKind.allCases.count)
        for k in InstrumentKind.allCases { XCTAssertFalse(k.symbol.isEmpty, "\(k) has a symbol") }
        // Everything the Ambient preset shows is a gauge.
        XCTAssertTrue(AmbientPlan.standard.allSatisfy(\.isGauge))
    }

    /// Existing users must see the Summary page unchanged: same instruments, same order, banners full width.
    func testDefaultLayoutIsTheClassicSummary() {
        let d = CockpitStore.defaults()
        XCTAssertEqual(d.current.name, "Default")
        XCTAssertEqual(d.current.preset, "default")
        XCTAssertEqual(d.current.slots.map(\.kind), [.annunciator, .findings, .cpu, .memory, .disk, .network, .energy, .thermals, .gpu, .topProcesses])
        XCTAssertEqual(d.current.slots.prefix(2).map(\.size), [.large, .large])
        XCTAssertTrue(d.current.slots.dropFirst(2).allSatisfy { $0.size == .small })
        XCTAssertEqual(d.layouts.map(\.name), ["Default", "Thermals", "Network", "Ambient"])
        XCTAssertEqual(Set(d.current.slots.map(\.id)).count, d.current.slots.count, "slot ids are unique")
    }

    func testMigrationFromNoSavedLayout() {
        XCTAssertEqual(CockpitStore.load(nil).current.slots.map(\.kind), CockpitStore.defaults().current.slots.map(\.kind))
        XCTAssertEqual(CockpitStore.load(Data("not json".utf8)).current.name, "Default")
        // An empty store is replaced; a stale selection or Ambient choice is repaired.
        let empty = CockpitStore(layouts: [], selected: UUID())
        XCTAssertEqual(CockpitStore.load(empty.encoded()).layouts.count, CockpitLayout.presets.count)
        var s = CockpitStore.defaults(); s.selected = UUID(); s.ambient = UUID()
        let fixed = CockpitStore.load(s.encoded())
        XCTAssertEqual(fixed.selected, s.layouts[0].id)
        XCTAssertNil(fixed.ambient)
    }

    func testJSONRoundTrip() throws {
        var s = CockpitStore.defaults()
        s.duplicateCurrent()
        s.editCurrent { $0.name = "Mine"; $0.add(.wifi, size: .medium); $0.setSize($0.slots[2].id, .large) }
        s.ambient = s.layouts[1].id
        let back = CockpitStore.load(s.encoded())
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.current.name, "Mine")
        XCTAssertEqual(back.current.slots.last?.kind, .wifi)
        XCTAssertEqual(back.ambientLayout?.name, "Thermals")
    }

    /// A layout saved by a newer version with a kind or size this one doesn't know keeps everything else.
    func testUnknownKindsAreDroppedNotFatal() throws {
        let json = """
        {"version":1,"selected":"6F0E5C3A-1111-4C1B-9E5B-000000000001","layouts":[{"id":"6F0E5C3A-1111-4C1B-9E5B-000000000001",
        "name":"Future","slots":[{"id":"6F0E5C3A-1111-4C1B-9E5B-0000000000A1","kind":"cpu","size":"small"},
        {"id":"6F0E5C3A-1111-4C1B-9E5B-0000000000A2","kind":"holodeck","size":"small"},
        {"kind":"memory","size":"gigantic"}]}]}
        """
        let s = CockpitStore.load(Data(json.utf8))
        XCTAssertEqual(s.current.name, "Future")
        XCTAssertEqual(s.current.slots.map(\.kind), [.cpu, .memory])
        XCTAssertEqual(s.current.slots[1].size, InstrumentKind.memory.defaultSize)
    }

    func testEditingOperations() {
        var l = CockpitLayout(name: "T", slots: [InstrumentSlot(.cpu), InstrumentSlot(.memory), InstrumentSlot(.disk), InstrumentSlot(.network)])
        let ids = l.slots.map(\.id)
        l.move(ids[0], onto: ids[2])                       // forward: lands after the target
        XCTAssertEqual(l.slots.map(\.kind), [.memory, .disk, .cpu, .network])
        l.move(ids[3], onto: ids[1])                       // back: lands before the target
        XCTAssertEqual(l.slots.map(\.kind), [.network, .memory, .disk, .cpu])
        l.move(ids[3], by: -5)                             // clamped
        XCTAssertEqual(l.slots.first?.kind, .network)
        l.move(ids[1], by: 1)
        XCTAssertEqual(l.slots.map(\.kind), [.network, .disk, .memory, .cpu])
        l.remove(ids[2])
        XCTAssertFalse(l.contains(.disk))
        let w = l.add(.wifi)
        l.setSize(w, .large)
        XCTAssertEqual(l.slots.last?.size, .large)
        l.reset()                                          // a user layout resets to the Default instruments
        XCTAssertEqual(l.slots.map(\.kind), CockpitLayout.presetSlots("default")?.map(\.kind))
    }

    func testDuplicateAndDelete() {
        var s = CockpitStore.defaults()
        s.duplicateCurrent(); s.duplicateCurrent()
        XCTAssertEqual(s.current.name, "Default Copy Copy")
        s.selected = s.layouts[0].id; s.duplicateCurrent()
        XCTAssertEqual(s.current.name, "Default Copy 2")
        XCTAssertNil(s.current.preset)
        XCTAssertTrue(Set(s.current.slots.map(\.id)).isDisjoint(with: s.layouts[0].slots.map(\.id)))
        let n = s.layouts.count
        s.deleteCurrent()
        XCTAssertEqual(s.layouts.count, n - 1)
        var one = CockpitStore(layouts: [CockpitLayout(name: "Only", slots: [])], selected: UUID())
        one.selected = one.layouts[0].id
        one.deleteCurrent()
        XCTAssertEqual(one.layouts.count, 1, "the last layout can't be deleted")
    }

    func testGridColumnsMatchAdaptiveGrid() {
        XCTAssertEqual(CockpitGrid.columns(width: 200), 1)
        XCTAssertEqual(CockpitGrid.columns(width: 611), 1)
        XCTAssertEqual(CockpitGrid.columns(width: 612), 2)   // 2 × 300 + 12
        XCTAssertEqual(CockpitGrid.columns(width: 924), 3)
        XCTAssertEqual(CockpitGrid.columns(width: 1068), 3)
    }

    func testPackingFlowsInOrder() {
        let p = CockpitGrid.pack([.large, .small, .small, .medium, .small, .large, .medium], columns: 3)
        XCTAssertEqual(p, [.init(row: 0, column: 0, span: 3),
                           .init(row: 1, column: 0, span: 1), .init(row: 1, column: 1, span: 1),
                           .init(row: 2, column: 0, span: 2),                                    // didn't fit in row 1
                           .init(row: 2, column: 2, span: 1),
                           .init(row: 3, column: 0, span: 3), .init(row: 4, column: 0, span: 2)])
        XCTAssertEqual(CockpitGrid.rowCount(p), 5)
        // One column: everything stacks, nothing spans more than the row.
        let narrow = CockpitGrid.pack([.large, .medium, .small], columns: 1)
        XCTAssertEqual(narrow.map(\.row), [0, 1, 2])
        XCTAssertTrue(narrow.allSatisfy { $0.span == 1 && $0.column == 0 })
        XCTAssertEqual(CockpitGrid.rowCount([]), 0)
        // The default layout at three columns: two banner rows, then the eight cards in rows of three.
        let d = CockpitGrid.pack(CockpitStore.defaults().current.slots.map(\.size), columns: 3)
        XCTAssertEqual(d.map(\.row), [0, 1, 2, 2, 2, 3, 3, 3, 4, 4])
    }

    func testAmbientGauges() {
        XCTAssertEqual(AmbientPlan.gauges(for: nil), AmbientPlan.standard)
        XCTAssertEqual(AmbientPlan.gauges(for: CockpitStore.defaults().ambientLayout), AmbientPlan.standard)
        // Non-gauges are skipped, duplicates collapse, order is kept.
        let l = CockpitLayout(name: "x", slots: [InstrumentSlot(.findings), InstrumentSlot(.wifi), InstrumentSlot(.cpu), InstrumentSlot(.wifi)])
        XCTAssertEqual(AmbientPlan.gauges(for: l), [.wifi, .cpu])
        XCTAssertEqual(AmbientPlan.gauges(for: CockpitLayout(name: "y", slots: [InstrumentSlot(.clock)])), AmbientPlan.standard)
        let many = CockpitLayout(name: "z", slots: InstrumentKind.allCases.map { InstrumentSlot($0) })
        XCTAssertEqual(AmbientPlan.gauges(for: many).count, AmbientPlan.maxGauges)
        // If the user deletes the Ambient layout, Ambient falls back to the standard gauges.
        var s = CockpitStore.defaults()
        s.selected = s.layouts.first { $0.preset == "ambient" }!.id
        s.deleteCurrent()
        XCTAssertNil(s.ambientLayout)
    }

    /// The shift stays within the amplitude, moves at most one point per minute, and cycles.
    func testBurnInShiftIsSlowAndBounded() {
        let a = 6
        var prev = BurnIn.offset(minute: -1, amplitude: a)
        var seen = Set<String>()
        for m in 0..<(8 * a) {
            let o = BurnIn.offset(minute: m, amplitude: a)
            XCTAssertLessThanOrEqual(abs(o.x), a); XCTAssertLessThanOrEqual(abs(o.y), a)
            XCTAssertLessThanOrEqual(abs(o.x - prev.x) + abs(o.y - prev.y), 1, "minute \(m)")
            seen.insert("\(o.x),\(o.y)"); prev = o
        }
        XCTAssertEqual(seen.count, 8 * a, "every perimeter point is visited once per cycle")
        XCTAssertTrue(BurnIn.offset(minute: 0, amplitude: a) == BurnIn.offset(minute: 8 * a, amplitude: a))
        XCTAssertEqual(BurnIn.minute(of: Date(timeIntervalSince1970: 125)), 2)
    }
}

/// Summary drill-down: every navigating instrument names a real page (and a real Performance tab).
final class CockpitDrillDownTests: XCTestCase {
    func testDrillDownTargetsAreRealPages() {
        let pages = ["Processes", "Stress Map", "Performance"]
        let tabs = ["CPU", "Memory", "Disk", "Network", "Energy", "Thermals", "GPU"]
        for k in InstrumentKind.allCases {
            guard let t = k.drillDown else { continue }
            let parts = t.split(separator: ":").map(String.init)
            XCTAssertTrue(pages.contains(parts[0]), "\(k) → \(t)")
            if parts.count > 1 { XCTAssertTrue(tabs.contains(parts[1]), "\(k) → \(t)") }
        }
        XCTAssertEqual(InstrumentKind.energy.drillDown, "Performance:Energy")
        XCTAssertEqual(InstrumentKind.battery.drillDown, "Performance:Energy")
        XCTAssertNil(InstrumentKind.findings.drillDown, "findings rows navigate one by one")
    }
}
