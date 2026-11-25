// Chrome tabs: matching renderer processes to tabs (client ids only count under the same live browser process), the
// renderer-argument cache, and the per-connection tab store.
import XCTest
@testable import FlightDeckCore

final class ChromeTabsResolverTests: XCTestCase {
    static let chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    static let rendererPath = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"

    func proc(pid: Int32, start: UInt64 = 1, ppid: Int32 = 1, name: String = "Google Chrome Helper (Renderer)",
              path: String = rendererPath) -> ProcessSample {
        ProcessSample(identity: ProcessIdentity(pid: pid, startTime: start), ppid: ppid, name: name, path: path,
                      user: "me", uid: 501, cpu: 0, cpuTime: 0, memory: 0, threads: 1, diskReadBps: 0, diskWriteBps: 0,
                      diskRead: 0, diskWritten: 0, energyWatts: nil, wakeups: 0, restricted: false)
    }
    func browser(_ pid: Int32 = 100, start: UInt64 = 1) -> ProcessSample { proc(pid: pid, start: start, name: "Google Chrome", path: Self.chromePath) }
    func renderer(_ client: Int, ext: Bool = false) -> [String] {
        [Self.rendererPath, "--type=renderer", "--lang=en-US"] + (ext ? ["--extension-process"] : []) + ["--renderer-client-id=\(client)"]
    }
    func frame(_ id: Int, _ process: Int, _ origin: String = "https://a.example") -> ChromeRawFrame {
        ChromeRawFrame(frameId: id, parentFrameId: id == 0 ? -1 : 0, processId: process, origin: origin)
    }
    func tab(_ id: Int, _ url: String, _ title: String, active: Bool = false, last: Double = 0, discarded: Bool = false,
             frames: [ChromeRawFrame]) -> ChromeRawTab {
        ChromeRawTab(tabId: id, windowId: 1, active: active, audible: false, discarded: discarded, url: url, title: title,
                     lastAccessed: last, frames: frames)
    }
    func key(_ b: ProcessSample, _ c: UInt64 = 1) -> ChromeTabStore.Key { ChromeTabStore.Key(browser: b.identity, connection: c) }
    func resolver(_ args: [Int32: [String]], calls: UnsafeMutablePointer<Int>? = nil) -> ChromeTabsResolver {
        ChromeTabsResolver { pid in calls?.pointee += 1; return args[pid] }
    }
    func id(_ pid: Int32, _ start: UInt64 = 1) -> ProcessIdentity { ProcessIdentity(pid: pid, startTime: start) }

    func testParseRendererArgsIncludingAperitif() {
        XCTAssertEqual(ChromeRendererArgs.parse(renderer(7)), ChromeRendererArgs(clientID: 7, isExtension: false))
        let aperitif = ["/x/Google Chrome Helper (Aperitif Renderer)", "--type=renderer", "--renderer-client-id=12"]
        XCTAssertEqual(ChromeRendererArgs.parse(aperitif)?.clientID, 12)
        XCTAssertNil(ChromeRendererArgs.parse(["/x/Google Chrome Helper (GPU)", "--type=gpu-process", "--renderer-client-id=3"]))
        XCTAssertNil(ChromeRendererArgs.parse(["/x", "--type=renderer"]), "no client id")
        XCTAssertNil(ChromeRendererArgs.parse(["/x", "--type=renderer", "--renderer-client-id=abc"]))
        XCTAssertEqual(ChromeRendererArgs.parse(renderer(4, ext: true))?.isExtension, true)
    }

    func testSeveralTabsOneRenderer() throws {
        let b = browser()
        let r = resolver([201: renderer(5)])
        let t = ChromeTabTable(seq: 1, tabs: [
            tab(1, "https://www.youtube.com/watch?v=1", "Lofi", last: 10, frames: [frame(0, 5)]),
            tab(2, "https://docs.google.com/d/x", "Plan", active: true, last: 5, frames: [frame(0, 5)]),
            tab(3, "https://music.youtube.com/", "Music", last: 20, frames: [frame(0, 5)]),
        ])
        let out = r.resolve(processes: [b, proc(pid: 201, ppid: 100)], tables: [key(b): t])
        let a = try XCTUnwrap(out[id(201)])
        XCTAssertEqual(a.tabCount, 3)
        XCTAssertEqual(a.entries.map(\.host), ["docs.google.com", "music.youtube.com", "www.youtube.com"], "active first, then most recent")
        XCTAssertFalse(a.isExtensionProcess)
    }

    func testOOPIFInOtherRenderer() throws {
        let b = browser()
        let r = resolver([201: renderer(5), 202: renderer(6)])
        let t = ChromeTabTable(seq: 1, tabs: [
            tab(1, "https://www.youtube.com/", "Lofi", frames: [frame(0, 5, "https://www.youtube.com"), frame(3, 6, "https://ads.example.net"),
                                                             frame(4, 6, "https://ads.example.net"), frame(5, 5, "https://www.youtube.com")]),
        ])
        let out = r.resolve(processes: [b, proc(pid: 201, ppid: 100), proc(pid: 202, ppid: 100)], tables: [key(b): t])
        XCTAssertEqual(out[id(201)]?.entries.count, 1, "the tab's own subframe collapses into its tab entry")
        XCTAssertEqual(out[id(201)]?.entries.first?.kind, .tab)
        let f = try XCTUnwrap(out[id(202)])
        XCTAssertEqual(f.entries.count, 1, "two frames of one tab in one process collapse")
        XCTAssertEqual(f.entries[0].kind, .frame(inTabHost: "www.youtube.com"))
        XCTAssertEqual(f.entries[0].host, "ads.example.net")
        XCTAssertEqual(f.tabCount, 0)
    }

    func testElectronClashingClientIDsExcludedByPPID() {
        let b = browser()
        let slack = proc(pid: 300, name: "Slack", path: "/Applications/Slack.app/Contents/MacOS/Slack")
        let slackRenderer = proc(pid: 301, ppid: 300, name: "Slack Helper (Renderer)", path: "/Applications/Slack.app/x")
        let r = resolver([301: renderer(5), 201: renderer(9)])
        let t = ChromeTabTable(seq: 1, tabs: [tab(1, "https://a.example/", "A", frames: [frame(0, 5)])])
        let out = r.resolve(processes: [b, slack, slackRenderer, proc(pid: 201, ppid: 100)], tables: [key(b): t])
        XCTAssertNil(out[id(301)], "client id 5 belongs to Chrome's renderers, not Slack's")
        XCTAssertTrue(out.isEmpty)
    }

    func testTwoBrowsersNeverMix() {
        let b1 = browser(100), b2 = browser(110)
        let r = resolver([201: renderer(5), 211: renderer(5)])
        let t1 = ChromeTabTable(seq: 1, tabs: [tab(1, "https://one.example/", "One", frames: [frame(0, 5)])])
        let t2 = ChromeTabTable(seq: 1, tabs: [tab(1, "https://two.example/", "Two", frames: [frame(0, 5)])])
        let out = r.resolve(processes: [b1, b2, proc(pid: 201, ppid: 100), proc(pid: 211, ppid: 110)],
                            tables: [key(b1, 1): t1, key(b2, 2): t2])
        XCTAssertEqual(out[id(201)]?.entries.map(\.host), ["one.example"])
        XCTAssertEqual(out[id(211)]?.entries.map(\.host), ["two.example"])
    }

    /// Review focus 4: two profiles under one browser merge; one disconnecting leaves the other's labels, and a second
    /// Chrome instance's client ids never cross over.
    func testProfileDisconnectKeepsOtherAndBrowsersNeverMix() {
        let b1 = browser(100), b2 = browser(110)
        let store = ChromeTabStore()
        let hello = ChromeTabStore.Hello(protocolVersion: 1, extensionVersion: "1.0.0")
        for k in [key(b1, 1), key(b1, 2), key(b2, 3)] { store.setHello(hello, for: k) }
        store.setTable(ChromeTabTable(seq: 1, tabs: [tab(1, "https://work.example/", "Work", frames: [frame(0, 5)])]), for: key(b1, 1))
        store.setTable(ChromeTabTable(seq: 1, tabs: [tab(1, "https://home.example/", "Home", frames: [frame(0, 6)])]), for: key(b1, 2))
        store.setTable(ChromeTabTable(seq: 1, tabs: [tab(1, "https://other.example/", "Other", frames: [frame(0, 6)])]), for: key(b2, 3))
        let procs = [b1, b2, proc(pid: 201, ppid: 100), proc(pid: 202, ppid: 100), proc(pid: 212, ppid: 110)]
        let r = resolver([201: renderer(5), 202: renderer(6), 212: renderer(6)])
        var out = r.resolve(processes: procs, tables: store.tables())
        XCTAssertEqual(out[id(201)]?.entries.map(\.host), ["work.example"])
        XCTAssertEqual(out[id(202)]?.entries.map(\.host), ["home.example"], "profiles merge; tab ids may repeat across them")
        XCTAssertEqual(out[id(212)]?.entries.map(\.host), ["other.example"])
        store.remove(key(b1, 1))
        out = r.resolve(processes: procs, tables: store.tables())
        XCTAssertNil(out[id(201)])
        XCTAssertEqual(out[id(202)]?.entries.map(\.host), ["home.example"])
        XCTAssertEqual(out[id(212)]?.entries.map(\.host), ["other.example"])
    }

    func testStaleTableRendererDiedNoLabel() {
        let b = browser()
        let r = resolver([201: renderer(5)])
        let t = ChromeTabTable(seq: 1, tabs: [tab(1, "https://a.example/", "A", frames: [frame(0, 7)])])
        let out = r.resolve(processes: [b, proc(pid: 201, ppid: 100)], tables: [key(b): t])
        XCTAssertTrue(out.isEmpty, "client id 7 isn't running; 5 isn't in the table")
    }

    /// Review focus 1: Chrome restarted with the same pid; the old browser's table must label nothing.
    func testBrowserRestartSamePIDNewStartTimeDropsLabels() {
        let old = browser(100, start: 1), new = browser(100, start: 2)
        let r = resolver([201: renderer(5)])
        let t = ChromeTabTable(seq: 1, tabs: [tab(1, "https://a.example/", "A", frames: [frame(0, 5)])])
        let out = r.resolve(processes: [new, proc(pid: 201, start: 3, ppid: 100)], tables: [key(old): t])
        XCTAssertTrue(out.isEmpty)
        let store = ChromeTabStore()
        store.setHello(.init(protocolVersion: 1, extensionVersion: "1"), for: key(old))
        store.setTable(t, for: key(old))
        store.prune(liveBrowsers: [new.identity])
        XCTAssertTrue(store.tables().isEmpty)
        XCTAssertEqual(store.hellos().count, 1, "the hello stays until the connection closes")
        store.setTable(t, for: key(old))
        XCTAssertEqual(store.tables().count, 1, "a sample that missed the browser doesn't silence the connection")
        store.remove(key(old))
        XCTAssertTrue(store.isEmpty)
    }

    func testDiscardedTabsAndNegativeProcessIdIgnored() {
        let b = browser()
        let r = resolver([201: renderer(5)])
        let t = ChromeTabTable(seq: 1, tabs: [
            tab(1, "https://gone.example/", "Gone", discarded: true, frames: [frame(0, 5)]),
            tab(2, "https://pending.example/", "Pending", frames: [frame(0, -1)]),
        ])
        XCTAssertTrue(r.resolve(processes: [b, proc(pid: 201, ppid: 100)], tables: [key(b): t]).isEmpty)
    }

    /// Review focus 3: a renderer that exits between the sample and the argument read gets no label, and nothing is
    /// cached for it, so it's read again next time.
    func testNilArgumentsNoLabelNotCached() {
        let b = browser()
        var calls = 0
        let r = resolver([:], calls: &calls)
        let t = ChromeTabTable(seq: 1, tabs: [tab(1, "https://a.example/", "A", frames: [frame(0, 5)])])
        XCTAssertTrue(r.resolve(processes: [b, proc(pid: 201, ppid: 100)], tables: [key(b): t]).isEmpty)
        XCTAssertEqual(r.cachedIdentityCount, 0)
        _ = r.resolve(processes: [b, proc(pid: 201, ppid: 100)], tables: [key(b): t])
        XCTAssertEqual(calls, 2)
    }

    func testNoTablesReadsNoArguments() {
        var calls = 0
        let r = resolver([201: renderer(5)], calls: &calls)
        XCTAssertTrue(r.resolve(processes: [browser(), proc(pid: 201, ppid: 100)], tables: [:]).isEmpty)
        XCTAssertEqual(calls, 0)
    }

    func testCachePrunedToLiveIdentities() {
        let b = browser()
        var calls = 0
        let r = resolver([201: renderer(5), 202: renderer(6), 300: ["/bin/zsh"]], calls: &calls)
        let t = ChromeTabTable(seq: 1, tabs: [tab(1, "https://a.example/", "A", frames: [frame(0, 5)])])
        _ = r.resolve(processes: [b, proc(pid: 201, ppid: 100), proc(pid: 202, ppid: 100)], tables: [key(b): t])
        XCTAssertEqual(r.cachedIdentityCount, 2)
        _ = r.resolve(processes: [b, proc(pid: 201, ppid: 100), proc(pid: 202, ppid: 100)], tables: [key(b): t])
        XCTAssertEqual(calls, 2, "read once per identity")
        _ = r.resolve(processes: [b, proc(pid: 201, ppid: 100)], tables: [key(b): t])
        XCTAssertEqual(r.cachedIdentityCount, 1)
        _ = r.resolve(processes: [b], tables: [:])
        XCTAssertEqual(r.cachedIdentityCount, 0)
    }

    func testExtensionRendererAndSanitisedTitle() throws {
        let b = browser()
        let r = resolver([201: renderer(5, ext: true), 202: renderer(6)])
        let t = ChromeTabTable(seq: 1, tabs: [tab(1, "https://A.Example/x", "Hi\u{202E}\nthere", frames: [frame(0, 6)])])
        let out = r.resolve(processes: [b, proc(pid: 201, ppid: 100), proc(pid: 202, ppid: 100)], tables: [key(b): t])
        XCTAssertEqual(out[id(201)]?.isExtensionProcess, true)
        XCTAssertEqual(out[id(201)]?.entries, [])
        let e = try XCTUnwrap(out[id(202)]?.entries.first)
        XCTAssertEqual(e.host, "a.example")
        XCTAssertEqual(e.title, "Hi there")
        XCTAssertEqual(e.url, "https://A.Example/x")
    }

    // MARK: Store

    /// Review focus 2: a table before `hello`, or after a hello with the wrong protocol, is ignored.
    func testTabsBeforeHelloIgnored() {
        let s = ChromeTabStore(), k = key(browser())
        let t = ChromeTabTable(seq: 1, tabs: [])
        s.setTable(t, for: k)
        XCTAssertTrue(s.tables().isEmpty)
        s.setHello(.init(protocolVersion: 1, extensionVersion: "1.0.0"), for: k)
        s.setTable(t, for: k)
        XCTAssertEqual(s.tables()[k], t)
    }

    func testProtocolMismatchIgnoresTables() {
        let s = ChromeTabStore(), k = key(browser())
        s.setHello(.init(protocolVersion: 2, extensionVersion: "2.0.0"), for: k)
        s.setTable(ChromeTabTable(seq: 1, tabs: []), for: k)
        XCTAssertTrue(s.tables().isEmpty)
        XCTAssertEqual(s.hellos()[k]?.protocolVersion, 2, "kept so Settings can say the extension needs updating")
        // A later hello with the wrong protocol also drops a table that was accepted before.
        let k2 = key(browser(), 2)
        s.setHello(.init(protocolVersion: 1, extensionVersion: "1"), for: k2)
        s.setTable(ChromeTabTable(seq: 1, tabs: []), for: k2)
        s.setHello(.init(protocolVersion: 3, extensionVersion: "3"), for: k2)
        XCTAssertNil(s.tables()[k2])
    }

    func testInvalidateDropsOnlyThatConnection() {
        let s = ChromeTabStore(), b = browser()
        for c: UInt64 in [1, 2] {
            s.setHello(.init(protocolVersion: 1, extensionVersion: "1"), for: key(b, c))
            s.setTable(ChromeTabTable(seq: 1, tabs: []), for: key(b, c))
        }
        s.invalidate(key(b, 1))
        XCTAssertEqual(Set(s.tables().keys), [key(b, 2)])
        XCTAssertNotNil(s.hellos()[key(b, 1)], "the hello stays")
        s.removeAll()
        XCTAssertTrue(s.isEmpty)
    }
}
