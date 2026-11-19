// DestinationTracker fed with synthetic nettop output through the real ProcessNetworkSampler, so the delta logic
// (new flows, counter resets) is the one the app runs. Names come from a fake lookup; nothing touches the network.
import XCTest
@testable import FlightDeckCore

final class DestinationTrackerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // a fixed instant; days are computed in UTC below
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    func proc(_ pid: Int32, _ name: String, path: String) -> ProcessSample {
        ProcessSample(identity: ProcessIdentity(pid: pid, startTime: 1), ppid: 1, name: name, path: path,
                      user: "me", uid: 501, cpu: 0, cpuTime: 0, memory: 0, threads: 1, diskReadBps: 0, diskWriteBps: 0,
                      diskRead: 0, diskWritten: 0, energyWatts: nil, wakeups: 0, restricted: false)
    }
    var procs: [ProcessSample] {
        [proc(100, "Slack", path: "/Applications/Slack.app/Contents/MacOS/Slack"),
         proc(101, "Slack Helper", path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"),
         proc(200, "curl", path: "/usr/bin/curl")]
    }
    /// nettop CSV with the given flow lines grouped under their process lines.
    func nettop(_ flows: [(String, String, UInt64, UInt64)]) -> String {
        var out = ",bytes_in,bytes_out,\n"
        for (procLine, flow, i, o) in flows { out += "\(procLine),0,0,\n\(flow),\(i),\(o),\n" }
        return out
    }
    /// A fake namer: names from `names`, answered on the namer's queue at once.
    func namer(_ names: [String: String]) -> HostNamer {
        var c = HostNamer.Config(); c.spacing = 0
        return HostNamer(config: c) { ip, _, q, done in q.async { done(names[ip]) } }
    }

    func testAccumulatesPerAppAndRemoteWithResets() {
        let n = namer(["203.0.113.5": "edge-1.slack.com", "203.0.113.6": "edge-2.slack.com"])
        let tr = DestinationTracker(store: nil, namer: n, calendar: cal, now: t0)
        let s = ProcessNetworkSampler()
        func run(_ k: Double, _ f: [(String, String, UInt64, UInt64)]) {
            let now = t0.addingTimeInterval(k)
            _ = s.ingest(nettop(f), now: now)
            tr.ingest(s.lastFlows, procs: procs, now: now)
        }
        let a = "tcp4 10.0.0.2:50000<->203.0.113.5:443", b = "tcp4 10.0.0.2:50001<->203.0.113.6:443"
        let lan = "udp4 10.0.0.2:5000<->192.168.1.9:8123"
        run(0, [("Slack.100", a, 1000, 100)])                                     // warm-up: baselines only
        run(1, [("Slack.100", a, 1500, 150), ("Slack Helper.101", b, 400, 40)])  // a: +500/+50 (open since warm-up); b: new, all counts
        run(2, [("Slack.100", a, 200, 20), ("curl.200", lan, 10, 5)])            // a's counter went down: reused tuple, all 200/20 is new
        n.drain()
        let rows = tr.today().rows
        let slack = rows.filter { $0.app == "/Applications/Slack.app" }
        XCTAssertEqual(slack.count, 2, "helper rolls up into the app; one row per IP")
        let ra = slack.first { $0.ip == "203.0.113.5" }!
        XCTAssertEqual(ra.bytesIn, 500 + 200); XCTAssertEqual(ra.bytesOut, 50 + 20)
        XCTAssertEqual(ra.connections, 1, "the warm-up flow counts once, a counter reset isn't a new connection")
        XCTAssertEqual(ra.host, "edge-1.slack.com"); XCTAssertEqual(ra.nameSource, .reverseDNS)
        XCTAssertEqual(ra.ports, [443]); XCTAssertEqual(ra.first, t0.addingTimeInterval(1)); XCTAssertEqual(ra.last, t0.addingTimeInterval(2))
        let rb = slack.first { $0.ip == "203.0.113.6" }!
        XCTAssertEqual(rb.bytesIn, 400); XCTAssertEqual(rb.connections, 1)
        let rl = rows.first { $0.app == "proc:curl" }!
        XCTAssertEqual(rl.scope, .privateLAN); XCTAssertEqual(rl.nameSource, .none, "no PTR record: 'no name', never invented")
        XCTAssertEqual(rl.protos, ["udp"])
        // Both Slack IPs share a registrable domain, so the report shows one destination.
        let rep = DestinationReport.build(days: [tr.today()], known: tr.known(), now: t0.addingTimeInterval(2), calendar: cal)
        let app = rep.first { $0.id == "/Applications/Slack.app" }!
        XCTAssertEqual(app.destinations.map(\.id), ["slack.com"])
        XCTAssertEqual(app.destinations[0].ipCount, 2); XCTAssertEqual(app.destinations[0].today, 700 + 70 + 400 + 40)
        XCTAssertFalse(app.destinations[0].isNew, "everything is new on the first day, so nothing is flagged")
    }

    func testSkipsUnconnectedAndCapsPerApp() {
        var cfg = DestinationTracker.Config(); cfg.maxPerApp = 2
        let tr = DestinationTracker(store: nil, namer: nil, config: cfg, calendar: cal, now: t0)
        func flow(_ ip: String) -> ProcessNetworkSampler.FlowDelta {
            let text = "tcp4 10.0.0.2:5000<->\(ip):443"
            return .init(pid: 200, flow: text[...], bytesIn: 10, bytesOut: 1, opened: true)
        }
        let unconnected = "udp4 *:5353<->*:*"
        tr.ingest([flow("198.51.100.1"), flow("198.51.100.2"), flow("198.51.100.3"), flow("198.51.100.4"),
                   .init(pid: 200, flow: unconnected[...], bytesIn: 99, bytesOut: 99, opened: true)], procs: procs, now: t0)
        let rows = tr.today().rows
        XCTAssertEqual(rows.count, 3, "two IPs, then one overflow row; the unconnected socket isn't a destination")
        XCTAssertEqual(rows.first { $0.isOther }?.bytesIn, 20)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.bytesIn }, 40)
        XCTAssertEqual(rows.first?.nameSource, .notLookedUp)
    }

    func testNewDestinationAfterLearningPeriod() {
        let tr = DestinationTracker(store: nil, namer: nil, calendar: cal, now: t0)
        func contact(_ ip: String, at k: Double) {
            let text = "tcp4 10.0.0.2:5000<->\(ip):443"
            tr.ingest([.init(pid: 100, flow: text[...], bytesIn: 1, bytesOut: 1, opened: true)], procs: procs, now: t0.addingTimeInterval(k))
        }
        contact("198.51.100.1", at: 0)
        contact("198.51.100.2", at: 3600)        // within the first day of watching Slack: learning, not flagged
        contact("198.51.100.1", at: 90_000)      // known
        contact("198.51.100.3", at: 90_000)      // new, the app is established
        let contacts = tr.newContacts(since: t0)
        XCTAssertEqual(contacts.map(\.dest), ["198.51.100.3"])
        XCTAssertEqual(contacts.first?.appName, "Slack")
        XCTAssertTrue(tr.known().isNew(app: "/Applications/Slack.app", dest: "198.51.100.3", now: t0.addingTimeInterval(90_100)))
        XCTAssertFalse(tr.known().isNew(app: "/Applications/Slack.app", dest: "198.51.100.3", now: t0.addingTimeInterval(90_000 + 86_401)))
        XCTAssertFalse(tr.known().isNew(app: "/Applications/Slack.app", dest: "198.51.100.2", now: t0.addingTimeInterval(3700)))

        // Findings: off by default; on, one finding per app per hour (later contacts join it).
        XCTAssertTrue(DestinationFindings.findings(contacts, settings: DestinationAlertSettings(), now: t0.addingTimeInterval(90_010)).isEmpty)
        var more = contacts
        more.append(.init(app: "/Applications/Slack.app", appName: "Slack", dest: "example.net", scope: .publicInternet, at: t0.addingTimeInterval(91_000)))
        more.append(.init(app: "/Applications/Safari.app", appName: "Safari", dest: "news.example", scope: .publicInternet, at: t0.addingTimeInterval(91_000)))
        more.append(.init(app: "proc:curl", appName: "curl", dest: "192.168.1.9", scope: .privateLAN, at: t0.addingTimeInterval(91_000)))
        let on = DestinationAlertSettings(enabled: true)
        let f = DestinationFindings.findings(more, settings: on, now: t0.addingTimeInterval(91_100))
        XCTAssertEqual(f.count, 1, "browser and local destinations are ignored by default")
        XCTAssertEqual(f.first?.title, "Slack contacted 2 new destinations")
        XCTAssertEqual(f.first?.since, t0.addingTimeInterval(90_000))
        XCTAssertTrue(f.first?.id.hasPrefix("privacy:dest:") == true)
        XCTAssertTrue(DestinationFindings.findings(more, settings: on, now: t0.addingTimeInterval(90_000 + 3601)).isEmpty, "the window has ended")
        XCTAssertEqual(DestinationFindings.findings(more, settings: DestinationAlertSettings(enabled: true, ignoreBrowsers: false, includeLocal: true),
                                                    now: t0.addingTimeInterval(91_100)).count, 3)
    }

    func testUnusualVolume() {
        let app = "proc:curl"
        func day(_ k: Int, _ bytes: UInt64) -> DestinationDay {
            let start = cal.date(byAdding: .day, value: -k, to: cal.startOfDay(for: t0))!
            var r = DestinationRow(app: app, appName: "curl", ip: "198.51.100.1", scope: .publicInternet, first: start, last: start)
            r.bytesIn = bytes
            return DestinationDay(start: start, rows: [r], firstCounted: start)
        }
        let days = [day(3, 1_000_000), day(2, 2_000_000), day(1, 3_000_000), day(0, 400_000_000)]
        let rep = DestinationReport.build(days: days, known: KnownDestinations(), now: t0, calendar: cal)
        let d = rep[0].destinations[0]
        XCTAssertTrue(d.unusual); XCTAssertEqual(d.typicalDay, 2_000_000); XCTAssertEqual(d.priorDays, 3)
        XCTAssertEqual(d.today, 400_000_000); XCTAssertEqual(d.month, 406_000_000)
        let calm = DestinationReport.build(days: Array(days.dropFirst()), known: KnownDestinations(), now: t0, calendar: cal)
        XCTAssertFalse(calm[0].destinations[0].unusual, "two earlier days aren't enough to call anything unusual")
        XCTAssertEqual(DestinationReport.search(rep, "198.51").count, 1)
        XCTAssertTrue(DestinationReport.search(rep, "nothing-like-this").isEmpty)
    }

    func testRetentionAndPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DestinationStore(dir: dir, calendar: cal)
        let today = cal.startOfDay(for: t0)
        for k in [0, 5, 29, 30, 45] {
            let start = cal.date(byAdding: .day, value: -k, to: today)!
            let r = DestinationRow(app: "proc:curl", appName: "curl", ip: "198.51.100.\(k)", scope: .publicInternet, first: start, last: start)
            store.save(DestinationDay(start: start, rows: [r]), known: KnownDestinations())
        }
        store.waitForWrites()
        store.prune(now: t0); store.waitForWrites()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "known.json" }.sorted()
        XCTAssertEqual(names.count, 3, "days 30 and 45 are past the 30-day retention: \(names)")
        let back = store.days(from: cal.date(byAdding: .day, value: -40, to: today)!, to: t0)
        XCTAssertEqual(back.map { $0.rows[0].ip }, ["198.51.100.29", "198.51.100.5", "198.51.100.0"])
        // The tracker resumes a saved open day after a relaunch, and known destinations are pruned after 30 days.
        var known = KnownDestinations()
        known.note(app: "a", name: "A", dest: "old.example", at: t0.addingTimeInterval(-40 * 86_400))
        known.note(app: "a", name: "A", dest: "recent.example", at: t0.addingTimeInterval(-86_400))
        known.prune(before: t0.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(Set(known.apps["a"]?.dests.keys.map { $0 } ?? []), ["recent.example"])
        let tr = DestinationTracker(store: store, namer: nil, calendar: cal, now: t0)
        XCTAssertEqual(tr.today().rows.map(\.ip), ["198.51.100.0"])
    }
}
