// Chrome tabs: the privacy boundary (tab data never reaches a saved model), the install flow (host manifest, stable
// extension copy, version checks), the Settings status, and MCP output (hosts only).
import XCTest
@testable import FlightDeckCore

final class ChromeTabsInstallTests: XCTestCase {
    // MARK: Privacy

    /// Tab data lives beside the samples, never in them: a Snapshot, the findings and the incidents built while the store
    /// holds a tab are encoded and searched for the tab's host, title and URL.
    func testPrivacyEncodedModelsCarryNoTabData() throws {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        var browser = AnalyzerTests.base.processes[0]
        browser.restricted = false; browser.identity = ProcessIdentity(pid: 100, startTime: 1); browser.ppid = 1
        browser.name = "Google Chrome"; browser.path = chrome; browser.uid = getuid(); browser.cpu = 1; browser.memory = 100_000_000
        browser.energyTotal = nil; browser.wakeups = 0; browser.diskReadBps = 0; browser.diskWriteBps = 0; browser.network = nil
        var renderer = browser
        renderer.identity = ProcessIdentity(pid: 201, startTime: 1); renderer.ppid = 100; renderer.cpu = 190
        renderer.name = "Google Chrome Helper (Renderer)"
        renderer.path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"

        let store = ChromeTabStore()
        let key = ChromeTabStore.Key(browser: browser.identity, connection: 1)
        store.setHello(.init(protocolVersion: 1, extensionVersion: "1.0.0"), for: key)
        store.setTable(ChromeTabTable(seq: 1, tabs: [
            ChromeRawTab(tabId: 1, windowId: 1, active: true, audible: true, discarded: false,
                         url: "https://sentinel-host.example/secret?q=1", title: "SENTINEL TITLE", lastAccessed: 1,
                         frames: [ChromeRawFrame(frameId: 0, parentFrameId: -1, processId: 5, origin: "https://sentinel-host.example")]),
        ]), for: key)
        let resolver = ChromeTabsResolver { $0 == 201 ? ["/x", "--type=renderer", "--renderer-client-id=5"] : nil }
        let tabs = resolver.resolve(processes: [browser, renderer], tables: store.tables())
        XCTAssertEqual(tabs[renderer.identity]?.entries.first?.host, "sentinel-host.example", "the fixture does resolve")

        let analyzer = Analyzer(), log = IncidentLog(url: nil)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var snap = AnalyzerTests.base
        var findings: [Finding] = []
        for i in 0..<180 where !findings.contains(where: { $0.id.hasPrefix("cpu:") }) || log.incidents.isEmpty {
            snap = AnalyzerTests.base
            snap.time = t0.addingTimeInterval(Double(i)); snap.cpu.total = .value(30); snap.processes = [browser, renderer]
            snap.memory.pressureLevel = 1; snap.memory.swapUsed = .value(0); snap.power.thermalState = 0; snap.power.battery = nil
            findings = analyzer.ingest(snap)
            log.update(findings, at: snap.time)
        }
        XCTAssertTrue(findings.contains { $0.id.hasPrefix("cpu:") }, "a Chrome CPU finding was raised")
        XCTAssertFalse(log.incidents.isEmpty)

        let enc = JSONEncoder()
        for data in [try enc.encode(snap), try enc.encode(findings), try enc.encode(log.incidents)] {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("sentinel"))
        }
    }

    // MARK: Install

    var dirs: [URL] = []
    override func tearDown() { for d in dirs { try? FileManager.default.removeItem(at: d) }; dirs = [] }
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("fdci-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    func testHostManifestShape() throws {
        let data = ChromeExtensionInstall.hostManifest(executablePath: "/Applications/FlightDeck.app/Contents/MacOS/FlightDeck")
        let j = try JSON.parse(data)
        XCTAssertEqual(j["name"]?.string, "app.flightdeck.chrome")
        XCTAssertEqual(j["type"]?.string, "stdio")
        XCTAssertEqual(j["path"]?.string, "/Applications/FlightDeck.app/Contents/MacOS/FlightDeck")
        XCTAssertEqual(j["allowed_origins"]?.array?.compactMap(\.string), ChromeTabsConstants.allowedOrigins)
        XCTAssertEqual(ChromeExtensionInstall.nativeHostsDir(home: URL(fileURLWithPath: "/Users/me")).path,
                       "/Users/me/Library/Application Support/Google/Chrome/NativeMessagingHosts")
        XCTAssertEqual(ChromeExtensionInstall.stableCopyDir(appSupport: URL(fileURLWithPath: "/a")).path, "/a/Flightdeck/ChromeExtension")
    }

    func testWriteHostManifestAtomicMode0644() throws {
        let d = tempDir().appendingPathComponent("NativeMessagingHosts")
        try ChromeExtensionInstall.writeHostManifest(dir: d, executablePath: "/x/FlightDeck")
        let f = d.appendingPathComponent("app.flightdeck.chrome.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: f.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: d.path), ["app.flightdeck.chrome.json"], "no temp file left behind")
        XCTAssertFalse(ChromeExtensionInstall.needsRewrite(existing: try Data(contentsOf: f), executablePath: "/x/FlightDeck"))
        ChromeExtensionInstall.removeHostManifest(dir: d)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    func testNeedsRewriteWhenPathDiffers() {
        let m = ChromeExtensionInstall.hostManifest(executablePath: "/old/FlightDeck")
        XCTAssertTrue(ChromeExtensionInstall.needsRewrite(existing: m, executablePath: "/new/FlightDeck"))
        XCTAssertFalse(ChromeExtensionInstall.needsRewrite(existing: m, executablePath: "/old/FlightDeck"))
        XCTAssertTrue(ChromeExtensionInstall.needsRewrite(existing: nil, executablePath: "/old/FlightDeck"))
        XCTAssertTrue(ChromeExtensionInstall.needsRewrite(existing: Data("{".utf8), executablePath: "/old/FlightDeck"))
        XCTAssertTrue(ChromeExtensionInstall.needsRewrite(existing: ChromeExtensionInstall.hostManifest(executablePath: "/old/FlightDeck", origins: []),
                                                          executablePath: "/old/FlightDeck"), "origins changed")
    }

    func testVersionCompare() {
        XCTAssertTrue(ChromeExtensionInstall.isVersion("1.0.10", newerThan: "1.0.9"))
        XCTAssertTrue(ChromeExtensionInstall.isVersion("1.1", newerThan: "1.0.9"))
        XCTAssertFalse(ChromeExtensionInstall.isVersion("1.0.0", newerThan: "1.0"))
        XCTAssertFalse(ChromeExtensionInstall.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertFalse(ChromeExtensionInstall.isVersion("1.0.8", newerThan: "1.0.9"))
        // ReleaseVersion's strict parsing: a version that isn't dotted digits is never newer, nor older than anything.
        XCTAssertFalse(ChromeExtensionInstall.isVersion("1.0.9", newerThan: "1.0.x"))
        XCTAssertFalse(ChromeExtensionInstall.isVersion("2.a", newerThan: "1.9"))
        XCTAssertFalse(ChromeExtensionInstall.isVersion("", newerThan: "1.0"))
    }

    func writeExtension(_ dir: URL, version: String, marker: String = "") throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"name":"FlightDeck Tabs","version":"\#(version)"}"#.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        try Data(marker.utf8).write(to: dir.appendingPathComponent("background.js"))
    }

    func testInstallStableCopyReplacesAtomically() throws {
        let base = tempDir()
        let bundled = base.appendingPathComponent("Bundled/ChromeExtension"), stable = base.appendingPathComponent("Support/Flightdeck/ChromeExtension")
        try writeExtension(bundled, version: "1.0.0", marker: "one")
        try ChromeExtensionInstall.installStableCopy(from: bundled, to: stable)
        XCTAssertEqual(ChromeExtensionInstall.manifestVersion(at: stable), "1.0.0")
        try writeExtension(bundled, version: "1.0.1", marker: "two")
        try ChromeExtensionInstall.installStableCopy(from: bundled, to: stable)
        XCTAssertEqual(ChromeExtensionInstall.manifestVersion(at: stable), "1.0.1")
        XCTAssertEqual(try String(contentsOf: stable.appendingPathComponent("background.js"), encoding: .utf8), "two")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stable.deletingLastPathComponent().path), ["ChromeExtension"],
                       "no temp folder left behind")
        ChromeExtensionInstall.removeStableCopy(stable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stable.path))
        XCTAssertNil(ChromeExtensionInstall.manifestVersion(at: stable))
    }

    // MARK: Status

    let hello1 = ChromeTabStore.Hello(protocolVersion: 1, extensionVersion: "1.0.0")
    func status(enabled: Bool = true, bundled: String? = "1.0.0", stable: String? = "1.0.0", manifest: Bool = true, relocatable: Bool = true,
                hellos: [ChromeTabStore.Hello] = [], tabs: Int = 0, error: String? = nil, installError: String? = nil) -> ChromeTabsStatus {
        ChromeTabsStatus.compute(enabled: enabled, bundledVersion: bundled, stableVersion: stable, manifestPresent: manifest,
                                 relocatable: relocatable, hellos: hellos, tabCount: tabs, listenerError: error, installError: installError)
    }

    /// A manifest that couldn't be written must still show once the listener starts fine, and both errors show together.
    func testInstallErrorShownBesideListener() {
        XCTAssertEqual(status(stable: nil, installError: "no manifest"), .error("no manifest"))
        XCTAssertEqual(status(installError: "no manifest"), .error("no manifest"), "not hidden behind Waiting for the extension")
        XCTAssertEqual(status(error: "sock", installError: "no manifest"), .error("sock\nno manifest"))
        XCTAssertEqual(status(enabled: false, installError: "no manifest"), .off)
        XCTAssertEqual(status(relocatable: false, installError: nil), .moveToApplications(reason: ChromeTabsStatus.moveReason))
    }

    /// Review focus 5: a `swift build` run has no bundled extension, so setup can't be offered.
    func testStatusUnbundled() {
        XCTAssertEqual(status(bundled: nil), .unbundled)
        XCTAssertEqual(status(bundled: nil).text, "Run from a bundled FlightDeck.app to set up Chrome tabs")
        XCTAssertEqual(status(enabled: false, bundled: nil), .off)
    }

    func testBundledNewerTriggersReloadStatus() {
        XCTAssertEqual(status(bundled: "1.0.1", stable: "1.0.0", hellos: [hello1], tabs: 3), .reloadNeeded(bundled: "1.0.1"))
        XCTAssertEqual(status(bundled: "1.0.1", stable: "1.0.1", hellos: [hello1], tabs: 3), .reloadNeeded(bundled: "1.0.1"),
                       "the stable copy is updated but Chrome still runs the old one")
        XCTAssertEqual(status(bundled: "1.0.0", stable: "1.0.0", hellos: [hello1], tabs: 3), .connected(tabs: 3))
        XCTAssertEqual(status(bundled: "1.0.0", stable: "1.0.0", hellos: [.init(protocolVersion: 1, extensionVersion: "1.2.0")], tabs: 3),
                       .connected(tabs: 3), "an extension ahead of the app (a store update) is fine")
        XCTAssertEqual(status(bundled: "1.0.1", stable: "1.0.0").text, "Extension updated — click Reload for FlightDeck Tabs in chrome://extensions")
    }

    func testStatusPrecedence() {
        XCTAssertEqual(status(enabled: false, error: "x"), .off)
        XCTAssertEqual(status(relocatable: false, error: "boom"), .error("boom"))
        XCTAssertEqual(status(relocatable: false), .moveToApplications(reason: "Move FlightDeck to Applications to use Chrome tabs"))
        XCTAssertEqual(status(hellos: [.init(protocolVersion: 2, extensionVersion: "2.0.0")]), .needsUpdating)
        XCTAssertEqual(status(stable: nil), .notSetUp)
        XCTAssertEqual(status(), .waiting)
        XCTAssertEqual(status(hellos: [hello1], tabs: 12), .connected(tabs: 12))
        XCTAssertEqual(status(hellos: [hello1], tabs: 12).text, "Connected, 12 tabs")
        XCTAssertEqual(status(hellos: [hello1], tabs: 1).text, "Connected, 1 tab")
        XCTAssertEqual(ChromeTabsStatus.off.text, "Off")
        XCTAssertEqual(ChromeTabsStatus.notSetUp.text, "Not set up")
        XCTAssertEqual(ChromeTabsStatus.waiting.text, "Waiting for the extension")
        XCTAssertEqual(ChromeTabsStatus.needsUpdating.text, "Extension needs updating")
    }

    // MARK: MCP

    /// FakeSource (MCPToolTests) plus Chrome tabs.
    final class TabsSource: MCPDataSource, @unchecked Sendable {
        let base: FakeSource; let tabs: ChromeTabsView?
        init(_ base: FakeSource, tabs: ChromeTabsView?) { self.base = base; self.tabs = tabs }
        var standalone: Bool { base.standalone }
        var blackBoxConfig: BlackBox.Config { base.blackBoxConfig }
        func snapshot() async -> Snapshot? { await base.snapshot() }
        func findings() async -> [Finding] { await base.findings() }
        func incidents() async -> [Incident] { await base.incidents() }
        func reports(since: Date) async -> [DiagnosticReport] { await base.reports(since: since) }
        func blackBox(_ tier: BlackBox.Tier, from: Date, to: Date) async -> Trace? { await base.blackBox(tier, from: from, to: to) }
        func dailyHistory() async -> DailyLog.History? { await base.dailyHistory() }
        func checkup() async -> [CheckResult] { await base.checkup() }
        func chromeTabs() async -> ChromeTabsView? { tabs }
    }

    func mcpTools(_ src: MCPDataSource) -> MCPTools {
        var t = MCPTools(source: src)
        t.inspector = { pid, _ in
            ProcessDetails(arguments: .value(["/x", "--type=renderer"]), environment: .unavailable("hidden"), cwd: .value("/"), files: .value([]),
                           sockets: [], threads: .unavailable("not permitted"), signature: nil, nice: 0, ancestry: [(pid, "r")], counters: nil)
        }
        return t
    }

    func text(_ t: MCPTools, _ name: String, _ args: JSON = [:]) async -> String {
        let r = await t.call(name, arguments: args)
        XCTAssertFalse(r.isError, r.text)
        return r.text
    }

    func testMCPHostsOnly() async throws {
        let helper = MCPToolTests()
        let base = FakeSource(); base.snap = helper.snapshot()
        base.findingList = [Finding(id: "cpu:x", severity: .caution, icon: "cpu", title: "Google Chrome is using 190% CPU", detail: nil,
                                    since: Date(), destination: nil, pids: [20, 21])]
        func e(_ host: String, _ title: String, _ url: String) -> ChromeTabEntry {
            ChromeTabEntry(kind: .tab, host: host, title: title, url: url, active: true, audible: false, lastAccessed: 1)
        }
        let attribution: [ProcessIdentity: ChromeTabAttribution] = [
            ProcessIdentity(pid: 20, startTime: 1): ChromeTabAttribution(entries: [e("mail.example.com", "Inbox (3) — secret", "https://mail.example.com/u/0?q=secret")], isExtensionProcess: false),
            ProcessIdentity(pid: 21, startTime: 1): ChromeTabAttribution(entries: [e("10.0.0.5", "Router", "http://10.0.0.5/admin"),
                                                                                    e("wiki", "Payroll", "http://wiki/payroll")], isExtensionProcess: false),
        ]
        let t = mcpTools(TabsSource(base, tabs: ChromeTabsView(attribution)))
        let list = await text(t, "list_processes")
        let process = await text(t, "get_process", ["pid": 21])
        let status = await text(t, "get_status")
        let all = list + process + status
        for want in ["mail.example.com", "IP address", "local network host"] { XCTAssertTrue(all.contains(want), want) }
        for banned in ["/u/0", "?q", "secret", "Inbox", "10.0.0.5", "\"wiki\"", "Payroll", "admin"] { XCTAssertFalse(all.contains(banned), banned) }
        let j = try JSON.parse(Data(list.utf8))
        XCTAssertEqual(j["columns"]?.array?.last?.string, "chrome_tabs")
        XCTAssertNil(j["chrome_tabs"])
        let row = try XCTUnwrap(j["rows"]?.array?.first { $0.array?.first?.int == 20 })
        XCTAssertEqual(row.array?.last, .strings(["mail.example.com"]))
        XCTAssertEqual(try JSON.parse(Data(process.utf8))["chrome_tabs"]?.array?.count, 2)
        XCTAssertEqual(try JSON.parse(Data(status.utf8))["findings"]?.array?.first?["chrome_tabs"]?.array?.count, 3)
    }

    func testMCPNilSourceOneTopLevelUnavailable() async throws {
        let base = FakeSource(); base.snap = MCPToolTests().snapshot()
        let j = try JSON.parse(Data(await text(mcpTools(base), "list_processes").utf8))
        XCTAssertEqual(j["chrome_tabs"]?.string, "unavailable (Chrome tabs are off, not connected, or this is the standalone server)")
        XCTAssertFalse(j["columns"]?.array?.contains("chrome_tabs") ?? true)
        let process = try JSON.parse(Data(await text(mcpTools(base), "get_process", ["pid": 20]).utf8))
        XCTAssertNil(process["chrome_tabs"])
        let byApp = try JSON.parse(Data(await text(mcpTools(base), "list_processes", ["by_app": true]).utf8))
        XCTAssertNil(byApp["chrome_tabs"], "the app-grouped table is unchanged")
    }

    func testMCPExistingColumnsOrderUnchanged() async throws {
        let base = FakeSource(); base.snap = MCPToolTests().snapshot()
        let j = try JSON.parse(Data(await text(mcpTools(TabsSource(base, tabs: ChromeTabsView([:]))), "list_processes").utf8))
        let cols = j["columns"]?.array?.compactMap(\.string) ?? []
        XCTAssertEqual(Array(cols.prefix(12)), ["pid", "name", "user", "cpu_percent", "memory", "energy_w", "gpu_percent", "disk", "network",
                                                 "wakeups_per_s", "threads", "flags"])
        XCTAssertEqual(cols.count, 13)
        XCTAssertTrue(j["rows"]?.array?.allSatisfy { $0.array?.count == 13 } ?? false)
    }
}
