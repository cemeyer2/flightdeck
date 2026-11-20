import XCTest
@testable import FlightDeckCore

final class ChangesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let home = "/Users/demo"

    func inv(_ t: TimeInterval, _ items: [InventoryItem], unavailable: [ChangeCategory: String] = [:], boot: Date? = nil) -> Inventory {
        Inventory(time: t0.addingTimeInterval(t), items: items, unavailable: unavailable, boot: boot)
    }
    func app(_ name: String, _ v: String, sig: SignatureState? = .developer, modified: Date? = nil) -> InventoryItem {
        InventoryItem(category: .app, key: "/Applications/\(name).app", name: name, version: v, path: "/Applications/\(name).app", signature: sig, modified: modified)
    }
    func agent(_ label: String, program: String, dir: String? = nil, sig: SignatureState = .developer) -> InventoryItem {
        let d = dir ?? home + "/Library/LaunchAgents"
        return InventoryItem(category: .launchItem, key: "\(d)/\(label).plist", name: label, scope: "Launch Agent (User)", path: "\(d)/\(label).plist",
                             program: program, signer: sig == .unsigned ? "Not signed" : "Signed: Developer ID Application: Example (ABCDE12345)",
                             signature: sig, runsAtLoad: true)
    }

    func testAddedRemovedUpdated() {
        let a = inv(0, [app("Notes Pro", "1.0"), app("Old", "2.0")])
        let b = inv(900, [app("Notes Pro", "1.1", modified: t0.addingTimeInterval(300)), app("Fresh", "3.0")])
        let e = ChangeDiff.diff(old: a, new: b, home: home)
        XCTAssertEqual(Set(e.map(\.kind)), [.added, .removed, .updated])
        let up = e.first { $0.kind == .updated }!
        XCTAssertEqual(up.summary, "Notes Pro updated: 1.0 → 1.1")
        XCTAssertEqual(up.estimated, t0.addingTimeInterval(300), "mtime between the checks is the better estimate")
        XCTAssertNil(e.first { $0.kind == .removed }!.estimated)
        XCTAssertFalse(e.contains(where: \.notable), "signed apps are not notable")
    }

    func testEstimateOutsideWindowIgnored() {
        let a = inv(0, []), b = inv(900, [app("Old Mtime", "1", modified: t0.addingTimeInterval(-86_400))])
        XCTAssertNil(ChangeDiff.diff(old: a, new: b, home: home)[0].estimated)
    }

    func testNotableLaunchAgents() {
        let a = inv(0, [])
        let b = inv(900, [agent("com.example.helper", program: "/tmp/.x/helper", sig: .unsigned),
                          agent("com.example.updater", program: "/Applications/Example.app/Contents/MacOS/updater")])
        let e = ChangeDiff.diff(old: a, new: b, home: home)
        let bad = e.first { $0.item.name == "com.example.helper" }!
        XCTAssertTrue(bad.notable)
        XCTAssertTrue(bad.reasons.contains("new launch agent that runs at login from ~/Library"))
        XCTAssertTrue(bad.reasons.contains { $0.hasPrefix("runs from a temporary") })
        XCTAssertTrue(bad.reasons.contains { $0.hasPrefix("unsigned") })
        XCTAssertTrue(bad.reasons.contains("its program is in a hidden folder"))
        XCTAssertFalse(e.first { $0.item.name == "com.example.updater" }!.notable)
        let home = ChangeDiff.assess(.added, agent("x", program: "/Users/demo/bin/x"), nil, home: "/Users/demo")
        XCTAssertTrue(home.notable)
    }

    func testModifiedProgram() {
        let a = inv(0, [agent("com.example.a", program: "/Applications/A.app/Contents/MacOS/a")])
        let b = inv(900, [agent("com.example.a", program: "/Users/Shared/a")])
        let e = ChangeDiff.diff(old: a, new: b, home: home)
        XCTAssertEqual(e.count, 1); XCTAssertEqual(e[0].kind, .modified); XCTAssertTrue(e[0].notable)
        XCTAssertTrue(e[0].summary.contains("now runs /Users/Shared/a"))
        XCTAssertTrue(ChangeDiff.diff(old: a, new: a, home: home).isEmpty)
    }

    func testUnavailableCategoryIsBaselineAndCarriedOver() {
        let k = InventoryItem(category: .kernelExtension, key: "com.example.kext", name: "com.example.kext", version: "1")
        let a = inv(0, [], unavailable: [.kernelExtension: "no kmutil"])
        let b = inv(900, [k])
        XCTAssertTrue(ChangeDiff.diff(old: a, new: b, home: home).isEmpty, "a reader that starts working is a baseline, not additions")
        // The reverse: a failed read keeps the old items instead of removing them.
        let c = ChangeDiff.carryOver(old: b, new: inv(1800, [], unavailable: [.kernelExtension: "timeout"]))
        XCTAssertEqual(c.items, [k])
        XCTAssertTrue(ChangeDiff.diff(old: b, new: c, home: home).isEmpty)
    }

    func testMacOSUpdateUsesBoot() {
        let os1 = InventoryItem(category: .macOS, key: "macOS", name: "macOS", version: "27.1 (26A1)")
        var os2 = os1; os2.version = "27.2 (26B123)"
        let e = ChangeDiff.diff(old: inv(0, [os1]), new: inv(3600, [os2], boot: t0.addingTimeInterval(1200)), home: home)
        XCTAssertEqual(e[0].summary, "macOS updated: 27.1 (26A1) → 27.2 (26B123)")
        XCTAssertEqual(e[0].estimated, t0.addingTimeInterval(1200))
        XCTAssertFalse(e[0].notable)
    }

    func testSharingAndProfiles() {
        let off = ChangeReaders.sharing(overrides: [:], plistDisabled: [:])
        XCTAssertTrue(off.allSatisfy { $0.state == "Off" })
        let on = ChangeReaders.sharing(overrides: ["com.openssh.sshd": false], plistDisabled: [:])
        let e = ChangeDiff.diff(old: inv(0, off), new: inv(900, on), home: home)
        XCTAssertEqual(e.count, 1); XCTAssertEqual(e[0].summary, "Remote Login (SSH) turned on"); XCTAssertTrue(e[0].notable)
        let p = ChangeReaders.profiles(user: "There are 1 user configuration profiles installed for 'demo'\ndemo[1] attribute: profileIdentifier: com.example.wifi\n",
                                       enrollment: "Enrolled via DEP: No\nMDM enrollment: Yes (User Approved)\n")
        XCTAssertEqual(p.map(\.name), ["com.example.wifi", "Enrolled via DEP", "MDM enrollment"])
        XCTAssertEqual(p[2].state, "Yes (User Approved)")
        XCTAssertTrue(ChangeDiff.assess(.added, p[0], nil).notable)
        XCTAssertTrue(ChangeReaders.profiles(user: "There are no configuration profiles installed for user 'demo'", enrollment: nil).isEmpty)
    }

    func testParsers() {
        let sx = "1 extension(s)\n--- com.apple.system_extension.driver_extension\nenabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n*\t*\tABCDE12345\tcom.example.driver (6.0.2/1)\tcom.example.driver\t[activated enabled]\n"
        let s = ChangeReaders.systemExtensions(sx)
        XCTAssertEqual(s.count, 1); XCTAssertEqual(s[0].version, "6.0.2/1"); XCTAssertEqual(s[0].teamID, "ABCDE12345")
        let kx = "Index Refs Address Size Wired Name (Version) UUID <Linked Against>\n  1  2 0xfff 0x1 0x1 com.apple.kpi.bsd (24.0.0) X <>\n 200 0 0xfff 0x1 0x1 com.example.kext (1.2.3) Y <1 2>\n"
        XCTAssertEqual(ChangeReaders.kernelExtensions(kx).map(\.key), ["com.example.kext"])
        XCTAssertEqual(ChangeReaders.kernelExtensions(kx).first?.version, "1.2.3")
        XCTAssertEqual(ChangeReaders.teamID("Signed: Developer ID Application: Example Corp (ABCDE12345)"), "ABCDE12345")
        XCTAssertNil(ChangeReaders.teamID("Signed by Apple"))
        XCTAssertEqual(ChangeReaders.macOS(["ProductVersion": "27.2", "ProductBuildVersion": "26B123"])?.version, "27.2 (26B123)")
    }

    func testHomebrewFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brew-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        for p in ["Cellar/jq/1.7", "Cellar/jq/1.8", "Caskroom/some-app/2.0", "Caskroom/some-app/.metadata"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(p)", withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: "\(root)/Cellar/jq/1.7")
        let items = ChangeReaders.homebrew(root: root).sorted { $0.key < $1.key }
        XCTAssertEqual(items.map(\.key), ["cask:some-app", "formula:jq"])
        XCTAssertEqual(items[1].version, "1.8")
    }

    func testStoreBaselineFindingsAndPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("changes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ChangeStore(dir: dir)
        XCTAssertTrue(store.ingest(inv(0, [app("A", "1"), agent("com.example.a", program: "/Applications/A.app/a")])).isEmpty, "the baseline has no changes")
        let found = store.ingest(inv(900, [app("A", "1"), app("Bad", "1", sig: .adHoc), agent("com.example.a", program: "/Applications/A.app/a")]))
        XCTAssertEqual(found.count, 1)
        let f = ChangeFindings.findings(found)
        XCTAssertEqual(f.count, 1); XCTAssertEqual(f[0].severity, .warning); XCTAssertEqual(f[0].destination, "What Changed")
        store.save()
        let again = ChangeStore(dir: dir, readOnly: true).report
        XCTAssertEqual(again.events.count, 1); XCTAssertEqual(again.baseline, t0); XCTAssertEqual(again.lastCheck, t0.addingTimeInterval(900))
        XCTAssertEqual(again.inventory?.items.count, 3)
        // Many notable changes at once become one finding.
        let many = (0..<5).map { i in ChangeDiff.event(.added, app("X\(i)", "1", sig: .unsigned), nil, old: inv(0, []), new: inv(900, []), home: home) }
        XCTAssertEqual(ChangeFindings.findings(many).count, 1)
    }

    func testReportFilteringAndDays() {
        let evs = [ChangeDiff.event(.added, app("Alpha", "1"), nil, old: inv(0, []), new: inv(900, []), home: home),
                   ChangeDiff.event(.added, agent("com.bad", program: "/tmp/x", sig: .unsigned), nil, old: inv(0, []), new: inv(90_000, []), home: home)]
        let r = ChangesReport(events: evs, baseline: t0, lastCheck: t0.addingTimeInterval(90_000), inventory: nil)
        XCTAssertEqual(r.filtered(categories: [.app]).count, 1)
        XCTAssertEqual(r.filtered(notableOnly: true).map(\.item.name), ["com.bad"])
        XCTAssertEqual(r.filtered(query: "alp").count, 1)
        XCTAssertEqual(r.filtered(query: "temporary").count, 1, "reasons are searchable")
        XCTAssertEqual(ChangesReport.byDay(evs).count, 2)
        let j = MCPTools.systemChangesJSON(r, since: t0, kinds: [], notableOnly: false, limit: 1, now: t0.addingTimeInterval(90_000))
        XCTAssertEqual(j["changes"]?.array?.count, 1)
        XCTAssertNotNil(j["truncated"])
        XCTAssertEqual(j["changes"]?.array?.first?["kind"]?.string, "launch_items")
        let empty = MCPTools.systemChangesJSON(ChangesReport(), since: t0, kinds: [], notableOnly: false, limit: 10, now: t0)
        XCTAssertTrue(empty["summary"]?.string?.hasPrefix("No inventory") ?? false)
    }

    /// The real readers on this Mac: they finish and find macOS and at least one category.
    func testLiveReadIsQuick() throws {
        let start = Date()
        let i = ChangeReaders.read(previous: nil)
        XCTAssertNotNil(i.items.first { $0.category == .macOS })
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
        // A second read a moment later finds (almost) nothing: no reader produces spurious differences.
        let again = ChangeReaders.read(previous: i, now: Date().addingTimeInterval(1))
        let diff = ChangeDiff.diff(old: i, new: ChangeDiff.carryOver(old: i, new: again))
        XCTAssertLessThan(diff.count, 3, diff.map(\.summary).joined(separator: "; "))
    }
}
