// Tests for the cockpit's page digests (PageDigests.swift, PageDigestsSystem.swift) and the instrument catalogue
// entries that show them.
import XCTest
@testable import FlightDeckCore

final class PageDigestTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day = 86_400.0

    func dest(_ id: String, first: Date, today: UInt64 = 0, isNew: Bool = false, unusual: Bool = false) -> DestinationSummary {
        var s = DestinationSummary(id: id, scope: .publicInternet, nameSource: .reverseDNS, first: first, last: now)
        s.bytesIn.today = today; s.isNew = isNew; s.unusual = unusual
        return s
    }

    func testDestinationsDigest() {
        let apps = [
            AppDestinations(id: "a", name: "Mail", destinations: [dest("old.com", first: now.addingTimeInterval(-10 * day), today: 5),
                                                                  dest("new1.com", first: now.addingTimeInterval(-3600), today: 1, isNew: true)]),
            AppDestinations(id: "b", name: "Photos", destinations: [dest("nas.local", first: now.addingTimeInterval(-20 * day), today: 900, unusual: true),
                                                                    dest("new2.com", first: now.addingTimeInterval(-600), today: 1, isNew: true),
                                                                    dest("big.com", first: now.addingTimeInterval(-20 * day), today: 2000, unusual: true),
                                                                    dest(DestinationRow.otherIP, first: now, today: 1, isNew: true)]),
        ]
        let d = DestinationsDigest.build(apps: apps, now: now, days: 14)
        XCTAssertEqual(d.newCount, 2, "the over-the-limit bucket is never a destination")
        XCTAssertEqual(d.newest?.label, "Photos → new2.com")
        XCTAssertEqual(d.unusualCount, 2)
        XCTAssertEqual(d.topUnusual?.destination, "big.com", "the heaviest unusual one leads")
        XCTAssertEqual(d.firstContactsPerDay.count, 14)
        XCTAssertEqual(d.firstContactsPerDay.reduce(0, +), 3, "20-day-old destinations fall outside the 14-day graph")
        XCTAssertEqual(DestinationsDigest.build(apps: [], now: now).newest, nil)
    }

    func testCameraMicDigest() {
        let zoom = SensorApp(name: "Zoom")
        let closed = SensorSession(kind: .camera, devices: ["cam"], app: zoom, confidence: .confirmed, how: "test",
                                   start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-5400))
        var live = CameraMicLive()
        var d = CameraMicDigest.build(live: live, sessions: [closed], now: now)
        XCTAssertFalse(d.anyInUse)
        XCTAssertEqual(d.last, CameraMicDigest.Use(kind: .camera, app: "Zoom", end: closed.end))
        XCTAssertEqual(d.cameraMinutes.reduce(0, +), 30, accuracy: 0.01)
        XCTAssertEqual(d.cameraMinutes.count, 24)

        let open = SensorSession(kind: .microphone, devices: ["mic"], app: zoom, confidence: .confirmed, how: "test", start: now.addingTimeInterval(-600))
        live.open = [open]
        live.running[.camera] = [SensorDevice(uid: "c", name: "FaceTime HD", kind: .camera)]
        d = CameraMicDigest.build(live: live, sessions: [closed, open], now: now)
        XCTAssertEqual(d.inUse.map(\.kind), [.camera, .microphone])
        XCTAssertEqual(d.inUse.first?.app, "unknown app", "a running camera without a session is not credited to anyone")
        XCTAssertEqual(d.micMinutes.reduce(0, +), 10, accuracy: 0.01, "the open session counts once")
    }

    func verdict(_ k: ShutdownVerdict.Kind, ended: Date? = nil) -> ShutdownVerdict {
        ShutdownVerdict(kind: k, title: k.rawValue, detail: "", cause: nil, panic: nil, ended: ended, evidence: [], inferred: false)
    }

    func testRestartsDigest() {
        var r = RestartsReport()
        let b0 = now.addingTimeInterval(-2 * day), b1 = now.addingTimeInterval(-9 * day), b2 = now.addingTimeInterval(-12 * day)
        r.events = [BootEvent(boot: b2, previousBoot: nil, previous: verdict(.unknown)),
                    BootEvent(boot: b0, previousBoot: b1, previous: verdict(.clean)),
                    BootEvent(boot: b1, previousBoot: b2, previous: verdict(.panic, ended: b1.addingTimeInterval(-60)))]
        let d = RestartsDigest.build(r, now: now)
        XCTAssertEqual(d.lastEnd, .clean)
        XCTAssertEqual(d.lastEndLabel, "clean")
        XCTAssertEqual(d.daysSinceUnexpected(now: now), 9)
        XCTAssertEqual(d.sessionDays.map { ($0 * 10).rounded() / 10 }, [3, 7, 2], "oldest first; the current session runs to now")
        XCTAssertNil(RestartsDigest.build(RestartsReport(), now: now).daysSinceUnexpected(now: now))
    }

    func record(_ boot: Date, desktop: TimeInterval) -> BootRecord {
        var rec = BootRecord(boot: boot)
        var t = BootTiming(boot: boot); t.desktop = boot.addingTimeInterval(desktop)
        rec.timing = t
        return rec
    }

    func testBootTimeDigest() {
        var r = RestartsReport()
        let cur = now.addingTimeInterval(-3600)
        var t = BootTiming(boot: cur); t.desktop = cur.addingTimeInterval(60)
        r.current = t
        r.history = [record(cur, desktop: 60), record(now.addingTimeInterval(-2 * day), desktop: 20),
                     record(now.addingTimeInterval(-4 * day), desktop: 30), record(now.addingTimeInterval(-6 * day), desktop: 25)]
        let d = BootTimeDigest.build(r, now: now)
        XCTAssertEqual(d.current, 60)
        XCTAssertEqual(d.earlierCount, 3, "the current boot isn't its own baseline")
        XCTAssertEqual(d.typical, 25)
        XCTAssertEqual(d.recent, [25, 30, 20, 60])
        XCTAssertTrue(d.isSlow)
        XCTAssertEqual(d.comparison, "typical 25 s · 35 s slower")
        r.history = [record(cur, desktop: 60), record(now.addingTimeInterval(-2 * day), desktop: 20)]
        XCTAssertNil(BootTimeDigest.build(r, now: now).typical, "one earlier boot is not a typical one")
    }

    func testBatteryHealthDigest() {
        let none = BatteryHealthDigest.build(BatteryReport(battery: nil, facts: nil, condition: nil, history: [], lifetime: nil))
        XCTAssertFalse(none.hasBattery)
        XCTAssertEqual(none.outlookLabel, "not enough data")
        let days = (0..<120).map { i -> BatteryDay in
            let start = now.addingTimeInterval(Double(i - 119) * day)
            return BatteryDay(day: "d\(i)", start: start, health: 95 - 3 * Double(i) / 119, cycles: i, source: .flightDeck)
        }
        let battery = try? JSONDecoder().decode(BatteryInfo.self, from: Data(#"{"percent": 64, "isCharging": false, "externalConnected": false, "cycleCount": 119}"#.utf8))
        XCTAssertNotNil(battery)
        let d = BatteryHealthDigest.build(BatteryReport(battery: battery, facts: nil, condition: nil, history: days, lifetime: nil))
        XCTAssertEqual(d.history.count, 120)
        XCTAssertEqual(d.health ?? 0, 92, accuracy: 0.01)
        if case .reaches(let date) = d.outlook { XCTAssertGreaterThan(date, now) } else { XCTFail("expected a forecast date, got \(d.outlook)") }
        XCTAssertEqual(d.graphFloor, 80)
    }

    func testFormats() {
        XCTAssertEqual(DigestFormat.span(42.4), "42 s")
        XCTAssertEqual(DigestFormat.span(125), "2 min 5 s")
        XCTAssertEqual(DigestFormat.uptime(3 * day + 4 * 3600 + 12 * 60), "3d 4h 12m")
        XCTAssertEqual(DigestFormat.ago(now.addingTimeInterval(-7200), now: now), "2 h ago")
    }

    func testPageInstrumentsInCatalogue() {
        for k in [InstrumentKind.destinations, .restarts, .bootTime, .batteryHealth, .cameraMic] {
            XCTAssertTrue(k.isGauge, "\(k) can be an Ambient gauge")
            XCTAssertEqual(k.defaultSize, .small)
            XCTAssertNotNil(k.drillDown)
        }
        // A layout saved by this version keeps them; an older build (which doesn't know them) drops just those slots.
        let l = CockpitLayout(name: "x", slots: [InstrumentSlot(.cpu), InstrumentSlot(.cameraMic, .medium)])
        let back = try? JSONDecoder().decode(CockpitLayout.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back?.slots.map(\.kind), [.cpu, .cameraMic])
        XCTAssertEqual(back?.slots.last?.size, .medium)
    }
}
