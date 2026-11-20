// Weekly Report: week ranges, incident sorting and hours, keeping aged-out days from the saved version, restarts,
// battery and storage, the digest's wording (headline, skipped sections, deltas), the schedule, the store and the
// `weekly_report` MCP tool. All on synthetic data in UTC.
import XCTest
@testable import FlightDeckCore

final class WeeklyReportTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    /// Monday 2026-11-16 00:00 UTC.
    var monday: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 16))! }
    func at(_ day: Int, _ hour: Double) -> Date { monday.addingTimeInterval(Double(day) * 86_400 + hour * 3600) }
    func inc(_ key: String, _ title: String = "t", _ detail: String? = nil, start: Date, minutes: Double, sev: Finding.Severity = .caution) -> Incident {
        Incident(id: UUID(), key: key, severity: sev, icon: "", title: title, detail: detail, destination: nil, start: start, end: start.addingTimeInterval(minutes * 60))
    }
    func day(_ i: Int) -> DayRecord {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        var d = DayRecord(day: f.string(from: at(i, 0)), start: at(i, 0)); d.observedSeconds = 3600; return d
    }

    func testWeekRangeStartsMonday() {
        let w = WeekRange.containing(at(6, 23.5), calendar: cal)   // Sunday night
        XCTAssertEqual(w.start, monday); XCTAssertEqual(w.end, at(7, 0)); XCTAssertEqual(w.id, "2026-11-16")
        XCTAssertEqual(WeekRange.containing(at(7, 0), calendar: cal).id, "2026-11-23")
        XCTAssertEqual(w.previous(calendar: cal).id, "2026-11-09")
    }

    func testClassifyAndUnion() {
        XCTAssertEqual(IncidentKinds.classify(inc("cpu:/Applications/Xcode.app", start: monday, minutes: 1))?.label, "Xcode kept the CPU busy")
        let mem = IncidentKinds.classify(inc("mem-pressure", "Memory pressure is elevated", "Biggest user: Safari (3 processes) with 3 GB.", start: monday, minutes: 1))
        XCTAssertEqual(mem?.kind, .memory); XCTAssertEqual(mem?.app, "Safari")
        XCTAssertEqual(IncidentKinds.classify(inc("hang:1-2", "Mail is not responding", start: monday, minutes: 1))?.app, "Mail")
        XCTAssertNil(IncidentKinds.classify(inc("restart:boot:1", start: monday, minutes: 1)))
        // Two overlapping hours and a separate half hour: 2.5 h, clipped to the window.
        let u = WeeklyReportBuilder.union([(at(0, 1), at(0, 2)), (at(0, 1.5), at(0, 3)), (at(0, 5), at(0, 5.5))], from: at(0, 0), to: at(0, 5.25))
        XCTAssertEqual(u / 3600, 2.25, accuracy: 0.001)
    }

    func sources(now: Date) -> WeeklySources {
        var s = WeeklySources(now: now)
        s.days = (0..<5).map(day)
        s.days[1].crashes = 2; s.days[1].crashesByProcess = ["Editor": 2]
        s.incidents = [inc("cpu:/Applications/Xcode.app", start: at(0, 10), minutes: 60), inc("cpu:/Applications/Xcode.app", start: at(0, 10.5), minutes: 60),
                       inc("thermal", start: at(2, 14), minutes: 90, sev: .warning), inc("cpu:x", start: at(-1, 10), minutes: 30)]
        s.restarts = [WeeklyEvent(time: at(3, 11), kind: .panic, title: "Kernel panic"), WeeklyEvent(time: at(-2, 9), kind: .unexpected, title: "Power loss")]
        s.boots = [at(0, 8), at(3, 11.1), at(-2, 9.1)]
        s.battery = [BatteryDay(day: "a", start: at(-1, 0), health: 90, cycles: 100, source: .demo),
                     BatteryDay(day: "b", start: at(2, 0), health: 89, cycles: 104, source: .demo),
                     BatteryDay(day: "c", start: at(4, 0), health: 89, cycles: 109, source: .demo)]
        s.storage = WeeklyStorage(readAt: now, used: 500_000_000_000, capacity: 1_000_000_000_000, fullInDays: nil)
        return s
    }

    func testBuildWeek() {
        let w = WeekRange.containing(monday, calendar: cal)
        let r = WeeklyReportBuilder.build(w, from: sources(now: at(4, 12)), calendar: cal)
        XCTAssertFalse(r.isFinal)
        XCTAssertEqual(r.days.count, 5)   // Monday to Friday so far
        XCTAssertEqual(r.cpuHours, 1.5, accuracy: 0.001)   // the two Xcode spans overlap; last week's isn't counted
        XCTAssertEqual(r.heatHours, 1.5, accuracy: 0.001)
        XCTAssertEqual(r.incidents.first?.label, "Xcode kept the CPU busy"); XCTAssertEqual(r.incidents.first?.count, 2)
        XCTAssertEqual(r.restarts.map(\.kind), [.panic]); XCTAssertEqual(r.boots, 2)
        XCTAssertEqual(r.crashes, 2); XCTAssertNil(r.hangs, "never counted stays nil, not 0")
        XCTAssertEqual(r.battery?.cyclesStart, 100); XCTAssertEqual(r.battery?.cyclesUsed, 9); XCTAssertEqual(r.battery?.healthChange, -1)
        XCTAssertNotNil(r.storage); XCTAssertNil(r.dataUsed)
    }

    func testAgedOutDaysKeepSavedTallies() {
        let w = WeekRange.containing(monday, calendar: cal)
        let early = WeeklyReportBuilder.build(w, from: sources(now: at(6, 23)), calendar: cal)
        XCTAssertTrue(early.days.allSatisfy(\.complete))
        // Nine days later the Flight Log no longer has Monday's incidents.
        var later = sources(now: at(9, 12)); later.incidents = []; later.storage = nil
        let r = WeeklyReportBuilder.build(w, from: later, saved: early, calendar: cal)
        XCTAssertTrue(r.isFinal)
        XCTAssertEqual(r.cpuHours, 1.5, accuracy: 0.001, "Monday's tallies come from the saved report")
        XCTAssertEqual(r.days.count, 7)
        XCTAssertNotNil(r.storage, "the reading saved during the week is kept")
        XCTAssertEqual(r.restarts.count, 1)
    }

    func testDigestWording() {
        let w = WeekRange.containing(monday, calendar: cal)
        let r = WeeklyReportBuilder.build(w, from: sources(now: at(9, 12)), calendar: cal)
        let d = WeeklyDigest.make(r, previous: nil)
        XCTAssertEqual(d.headline, "A rough week: 1 kernel panic"); XCTAssertTrue(d.rough)
        XCTAssertEqual(Set(d.sections.map(\.id)), ["slowdowns", "restarts", "battery"], "no storage (read too late), network or comparison")
        XCTAssertTrue(d.markdown.contains("## Battery")); XCTAssertTrue(d.markdown.contains("Used 9 charge cycles (100 → 109)."))

        var calmSrc = WeeklySources(now: at(9, 12)); calmSrc.days = (0..<7).map(day)
        let calm = WeeklyReportBuilder.build(w, from: calmSrc, calendar: cal)
        XCTAssertEqual(WeeklyDigest.make(calm, previous: nil).headline, "A calm week")
        let next = WeeklyReportBuilder.build(WeekRange.containing(at(7, 0), calendar: cal), from: calmSrc, calendar: cal)
        XCTAssertEqual(WeeklyDigest.make(next, previous: nil).headline, "Not much recorded this week")
        // Deltas against the busy week.
        let cmp = WeeklyDigest.make(calm, previous: r).sections.first { $0.id == "compared" }
        XCTAssertTrue(cmp?.lines.contains { $0.text == "Unexpected restarts and panics: 0, down from 1 the week before." && $0.tone == .good } ?? false)
    }

    func testSchedule() {
        // Monday 9:00; the Mac slept through it and woke on Tuesday.
        let tuesday = at(1, 7)
        XCTAssertEqual(WeeklySchedule.lastOccurrence(before: tuesday, weekday: 2, minutes: 540, calendar: cal), at(0, 9))
        XCTAssertEqual(WeeklySchedule.due(now: tuesday, lastDelivered: at(-3, 0), weekday: 2, minutes: 540, calendar: cal), at(0, 9))
        XCTAssertNil(WeeklySchedule.due(now: tuesday, lastDelivered: at(0, 9.5), weekday: 2, minutes: 540, calendar: cal))
        XCTAssertNil(WeeklySchedule.due(now: tuesday, lastDelivered: nil, weekday: 2, minutes: 540, calendar: cal), "just turned on")
        XCTAssertNil(WeeklySchedule.due(now: at(0, 8), lastDelivered: at(-3, 0), weekday: 2, minutes: 540, calendar: cal).flatMap { $0 > at(-3, 0) ? $0 : nil })
        XCTAssertEqual(WeeklySchedule.week(for: at(0, 9), calendar: cal).id, "2026-11-09")
    }

    func testStoreRoundTripAndRefresh() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("weekly-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WeeklyReportStore(dir: dir)
        let all = WeeklyReports.refresh(store: store, sources: sources(now: at(9, 12)), calendar: cal)
        XCTAssertEqual(all.map(\.id), ["2026-11-23", "2026-11-16"])
        let again = WeeklyReportStore(dir: dir, readOnly: true)
        let saved = try XCTUnwrap(again.load("2026-11-16"))
        XCTAssertTrue(saved.isFinal); XCTAssertEqual(saved.cpuHours, all[1].cpuHours, accuracy: 0.001)
        // A final week isn't rebuilt from sources that have lost its data.
        _ = WeeklyReports.refresh(store: store, sources: WeeklySources(now: at(10, 0)), calendar: cal)
        XCTAssertEqual(WeeklyReportStore(dir: dir).load("2026-11-16")?.incidentCount, saved.incidentCount)
    }

    func testMCPTool() async throws {
        let src = FakeSource()
        src.days = (0..<5).map(day)
        src.incidentList = [inc("mem-pressure", "Memory pressure is elevated", "Biggest user: Safari with 3 GB.", start: at(1, 9), minutes: 120)]
        var t = MCPTools(source: src)
        let fixedNow = at(4, 12); t.now = { fixedNow }
        t.weeklyStore = WeeklyReportStore(dir: nil)
        t.restartsReader = { nil }
        let out = try JSON.parse(Data(await t.call("weekly_report", arguments: ["weeks_ago": 0]).text.utf8))
        XCTAssertEqual(out["status"]?.string, "in progress")
        XCTAssertEqual(out["slowdowns"]?["memory_pressure_hours"], .double(2))
        XCTAssertTrue(out["text"]?.string?.contains("# Weekly Report") ?? false)
        XCTAssertTrue(out["restarts"]?["boots"]?.string?.hasPrefix("unavailable") ?? false)
        let old = try JSON.parse(Data(await t.call("weekly_report", arguments: ["weeks_ago": 30]).text.utf8))
        XCTAssertTrue(old["summary"]?.string?.hasPrefix("No Weekly Report") ?? false)
    }
}
