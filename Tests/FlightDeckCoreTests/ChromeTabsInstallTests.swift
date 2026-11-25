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
}
