// Tests for the process catalog's matcher (which entry a process gets, and whether it is vouched for) and its wording.
// Every case here uses a small hand-written fixture catalog, so the results don't depend on the shipped entries;
// ProcessCatalogContentTests checks the real catalog.
import XCTest
@testable import FlightDeckCore

final class ProcessCatalogTests: XCTestCase {
    static let mdworkerPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/Support/mdworker_shared"
    static let chromeMain = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    static let chromeHelpers = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/131.0.6778.86/Helpers/"
    static let webContent = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"

    static func entry(_ id: String, maker: ProcessExplanation.Maker = .apple, quit: ProcessExplanation.QuitSafety = .relaunches,
                      whatToDo: String? = nil, managed: Bool = false, names: [String] = [], namePrefixes: [String] = [],
                      paths: [String] = [], pathPrefixes: [String] = [], bundleIDs: [String] = [], teamIDs: [String] = []) -> ProcessExplanation {
        ProcessExplanation(id: id, title: "Title \(id)", summary: "Summary of \(id).", maker: maker, busyWhen: "Busy after \(id) work.",
                           quit: quit, whatToDo: whatToDo, findingNote: "Note for \(id).", managed: managed, names: names,
                           namePrefixes: namePrefixes, paths: paths, pathPrefixes: pathPrefixes, bundleIDs: bundleIDs,
                           teamIDs: teamIDs, groundedIn: "x-man-page://8/\(id)")
    }

    /// About ten entries covering every key kind, an Apple and a vendor side, and a longer prefix inside a shorter one.
    static func fixture() -> ProcessCatalog {
        ProcessCatalog(entries: [
            entry("mdworker", names: ["mdworker_shared"], bundleIDs: ["com.apple.mdworker_shared"]),
            entry("windowserver", quit: .never, paths: ["/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"]),
            entry("webkit", quit: .safe, namePrefixes: ["com.apple.WebKit."]),
            entry("chrome", maker: .vendor("Google"), quit: .app, pathPrefixes: ["/Applications/Google Chrome.app/"],
                  bundleIDs: ["com.google.Chrome"], teamIDs: ["EQHXZ8M8AV"]),
            entry("chrome-helper", maker: .vendor("Google"), quit: .safe, pathPrefixes: [chromeHelpers]),
            entry("dropbox", maker: .vendor("Dropbox"), quit: .avoid, names: ["Dropbox"], pathPrefixes: ["/Applications/Dropbox.app/"]),
            entry("coreaudiod", quit: .avoid, names: ["coreaudiod"], paths: ["/usr/sbin/coreaudiod"]),
            entry("crowdstrike", maker: .vendor("CrowdStrike"), quit: .avoid, whatToDo: "Contact your IT team if it stays busy.", managed: true,
                  names: ["falcond"], pathPrefixes: ["/Library/CS/"]),
            entry("logd", names: ["logd"], paths: ["/usr/libexec/logd"]),
            entry("system-tool", namePrefixes: ["com.apple.W"]),
            entry("libexec", pathPrefixes: ["/usr/libexec/"]),
        ])
    }

    /// `anchored` defaults to "a team ID means an Apple-issued certificate for that team"; pass false for a self-signed one.
    static func sig(apple: Bool = false, valid: Bool = true, team: String? = nil, anchored: Bool? = nil, id: String? = nil) -> ProcessDetails.Signature {
        ProcessDetails.Signature(identifier: id, teamID: team, authority: [], isApple: apple, valid: valid, hardenedRuntime: false,
                                 teamAnchored: anchored ?? (team != nil))
    }

    func id(_ m: ProcessMatch) -> String? { m.known?.id }
    func key(_ m: ProcessMatch) -> MatchKey? { if case .known(_, let k, _) = m { return k }; return nil }
    func verified(_ m: ProcessMatch) -> Bool? { if case .known(_, _, let v) = m { return v }; return nil }
    func isLookalike(_ m: ProcessMatch) -> Bool { if case .lookalike = m { return true }; return false }
    func reason(_ m: ProcessMatch) -> LookalikeReason? { if case .lookalike(_, let r) = m { return r }; return nil }

    /// Each step beats the next: exact path, path prefix, exact name, name prefix, bundle ID.
    func testPrecedence() {
        let c = Self.fixture()
        let ws = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
        // an exact path beats a path prefix ("/usr/libexec/" is a short prefix covering logd)
        XCTAssertEqual(key(c.lookup(name: "logd", path: "/usr/libexec/logd", signature: nil)), .path)
        XCTAssertEqual(id(c.lookup(name: "other", path: "/usr/libexec/other", signature: nil)), "libexec")
        XCTAssertEqual(id(c.lookup(name: "WindowServer", path: ws, signature: nil)), "windowserver")
        // a path prefix beats an exact name: Dropbox's name key loses to Chrome's prefix
        let m = c.lookup(name: "Dropbox", path: "/Applications/Google Chrome.app/Contents/MacOS/x", signature: nil)
        XCTAssertEqual(id(m), "chrome"); XCTAssertEqual(key(m), .pathPrefix)
        // an exact name beats a name prefix
        XCTAssertEqual(key(c.lookup(name: "mdworker_shared", path: "", signature: nil)), .name)
        let n = c.lookup(name: "com.apple.WebKit.Networking", path: "", signature: nil)
        XCTAssertEqual(id(n), "webkit", "the longer name prefix wins"); XCTAssertEqual(key(n), .namePrefix)
        // a name prefix beats a bundle ID
        let b = c.lookup(name: "com.apple.WebKit.GPU", path: "", signature: Self.sig(apple: true, id: "com.apple.mdworker_shared"))
        XCTAssertEqual(id(b), "webkit")
    }

    func testLongestPrefixWins() {
        let c = Self.fixture()
        let m = c.lookup(name: "Google Chrome Helper (GPU)", path: Self.chromeHelpers + "Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)", signature: nil)
        XCTAssertEqual(id(m), "chrome-helper")
        XCTAssertEqual(id(c.lookup(name: "Google Chrome", path: Self.chromeMain, signature: nil)), "chrome")
    }

    /// An Apple name is vouched for only in macOS's own folders, with an unreadable path, or with Apple's signature.
    func testLookalikeGuard() {
        let c = Self.fixture()
        let real = c.lookup(name: "mdworker_shared", path: Self.mdworkerPath, signature: nil)
        XCTAssertEqual(id(real), "mdworker"); XCTAssertEqual(verified(real), true)
        XCTAssertTrue(isLookalike(c.lookup(name: "mdworker_shared", path: "/Users/x/Downloads/mdworker_shared", signature: nil)))
        XCTAssertTrue(isLookalike(c.lookup(name: "mdworker_shared", path: "/usr/local/bin/mdworker_shared", signature: nil)))
        XCTAssertEqual(reason(c.lookup(name: "mdworker_shared", path: "/usr/local/bin/mdworker_shared", signature: nil)), .location)
        XCTAssertTrue(isLookalike(c.lookup(name: "mdworker_shared", path: "/System/Volumes/Data/Users/x/mdworker_shared", signature: nil)),
                      "the writable Data volume is not one of macOS's own folders")
        XCTAssertEqual(verified(c.lookup(name: "mdworker_shared", path: "", signature: nil)), false)
        XCTAssertEqual(id(c.lookup(name: "mdworker_shared", path: "/opt/odd/mdworker_shared", signature: Self.sig(apple: true, valid: true))), "mdworker")
        // a lookalike is never reported as known anywhere
        XCTAssertNil(c.lookup(name: "mdworker_shared", path: "/usr/local/bin/mdworker_shared", signature: nil).known)
    }

    /// A signing identifier is whatever the signer typed, so it only counts with a real signature from the right signer.
    func testBundleIDNeedsRealSignature() {
        let c = Self.fixture()
        XCTAssertTrue(isLookalike(c.lookup(name: "worker", path: "/opt/x/worker", signature: Self.sig(apple: false, valid: true, id: "com.apple.mdworker_shared"))))
        XCTAssertTrue(isLookalike(c.lookup(name: "chrome", path: "/opt/x/chrome", signature: Self.sig(team: "WRONGTEAM", id: "com.google.Chrome"))))
        XCTAssertTrue(isLookalike(c.lookup(name: "chrome", path: "/opt/x/chrome", signature: Self.sig(valid: false, team: "EQHXZ8M8AV", id: "com.google.Chrome"))))
        let ok = c.lookup(name: "chrome", path: "/opt/x/chrome", signature: Self.sig(team: "EQHXZ8M8AV", id: "com.google.Chrome"))
        XCTAssertEqual(id(ok), "chrome"); XCTAssertEqual(key(ok), .bundleID)
        // a path-prefix match with a signature from another team is a lookalike too
        XCTAssertEqual(reason(c.lookup(name: "Google Chrome", path: Self.chromeMain, signature: Self.sig(team: "WRONGTEAM"))), .signer)
        XCTAssertEqual(reason(c.lookup(name: "worker", path: "/opt/x/worker", signature: Self.sig(apple: false, valid: true, id: "com.apple.mdworker_shared"))), .signer)
    }

    /// A vendor's name somewhere odd is not the vendor's program.
    func testVendorNameAtOddPathIsLookalike() {
        let c = Self.fixture()
        XCTAssertTrue(isLookalike(c.lookup(name: "Dropbox", path: "/Users/x/Downloads/Dropbox", signature: nil)))
        XCTAssertEqual(reason(c.lookup(name: "Dropbox", path: "/Users/x/Downloads/Dropbox", signature: nil)), .location)
        let hidden = c.lookup(name: "Dropbox", path: "", signature: nil)
        XCTAssertEqual(id(hidden), "dropbox"); XCTAssertEqual(verified(hidden), false)
        XCTAssertEqual(verified(c.lookup(name: "Dropbox", path: "/Applications/Dropbox.app/Contents/MacOS/Dropbox", signature: nil)), true)
    }

    /// A root daemon's path is unreadable while the helper is locked or absent: it matches by name, unverified (H2).
    func testLockedHelperNameOnly() {
        let c = Self.fixture()
        XCTAssertEqual(verified(c.lookup(name: "coreaudiod", path: "", signature: nil)), false)
        XCTAssertEqual(verified(c.lookup(name: "coreaudiod", path: "/usr/sbin/coreaudiod", signature: nil)), true)
    }

    /// The row has no signature and the inspector does; whenever the row names an entry, the inspector names the same one.
    func testRowInspectorAgreement() {
        let c = Self.fixture()
        let chromeSig = Self.sig(team: "EQHXZ8M8AV", id: "com.google.Chrome")
        let apple = Self.sig(apple: true, id: "com.apple.x")
        let list: [(String, String, ProcessDetails.Signature)] = [
            ("Google Chrome", Self.chromeMain, chromeSig),
            ("Google Chrome Helper (GPU)", Self.chromeHelpers + "Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)", chromeSig),
            ("Google Chrome Helper (Renderer)", Self.chromeHelpers + "Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", chromeSig),
            ("WindowServer", "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer", apple),
            ("mdworker_shared", Self.mdworkerPath, apple),
            ("com.apple.WebKit.WebContent", Self.webContent, apple),
        ]
        for (n, p, s) in list {
            let row = c.lookup(name: n, path: p, signature: nil)
            XCTAssertNotNil(row.known, n)
            if let e = row.known { XCTAssertEqual(c.lookup(name: n, path: p, signature: s).known?.id, e.id, n) }
        }
    }

    /// Groups are looked up by their key, never by the "Name (N)" display name.
    func testGroupLookupUsesKeyNotDisplayName() {
        let c = Self.fixture()
        XCTAssertEqual(id(c.lookup(groupKey: "/Applications/Google Chrome.app", name: "Google Chrome", memberPath: "")), "chrome")
        XCTAssertTrue(isLookalike(c.lookup(groupKey: "proc:mdworker_shared", name: "mdworker_shared", memberPath: "/Users/x/mdworker_shared")))
        XCTAssertEqual(id(c.lookup(groupKey: "proc:mdworker_shared", name: "mdworker_shared (3)", memberPath: Self.mdworkerPath)), "mdworker")
    }

    func testMainMember() {
        func p(_ path: String, _ pid: Int32) -> ProcessSample { var s = AnalyzerTests().proc("x", path: path, pid: pid); s.path = path; return s }
        let key = "/Applications/Google Chrome.app"
        let helper1 = p(Self.chromeHelpers + "Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", 2)
        let helper2 = p(Self.chromeHelpers + "Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)", 3)
        let main = p(Self.chromeMain, 1)
        XCTAssertEqual(ProcessCatalog.mainMember(groupKey: key, [helper1, main, helper2])?.pid, 1)
        XCTAssertEqual(ProcessCatalog.mainMember(groupKey: key, [helper2, helper1])?.pid, 3)
        XCTAssertNil(ProcessCatalog.mainMember(groupKey: key, []))
    }

    func testEntryByID() {
        let c = Self.fixture()
        XCTAssertEqual(c.entry(id: "logd")?.names, ["logd"])
        XCTAssertNil(c.entry(id: "nope"))
        XCTAssertEqual(c.entry(id: "chrome")?.makerName, "Google")
        XCTAssertEqual(c.entry(id: "logd")?.makerName, "Apple")
    }

    // MARK: wording

    func known(_ e: ProcessExplanation, verified: Bool = true) -> ProcessMatch { .known(e, by: .name, pathVerified: verified) }

    /// A match adds a note but never takes the finding's action line away, and a managed agent is never told to quit.
    func testFindingDetailKeepsActionForEveryQuitCase() {
        let action = "Quit it or let it finish if you don't need it right now."
        for q in ProcessExplanation.QuitSafety.allCases {
            let e = Self.entry("e-\(q.rawValue)", quit: q)
            let d = ProcessCatalogText.findingDetail(known(e), defaultAction: action)
            XCTAssertTrue(d.hasPrefix(e.findingNote), d); XCTAssertGreaterThan(d.count, e.findingNote.count + 1, d)
            switch q {
            case .relaunches, .never: XCTAssertTrue(d.contains("won't help"), d)
            case .safe, .avoid, .app: XCTAssertTrue(d.hasSuffix(action), d)
            }
        }
        let m = Self.fixture().entry(id: "crowdstrike")!
        let d = ProcessCatalogText.findingDetail(known(m), defaultAction: action)
        XCTAssertTrue(d.hasPrefix(m.findingNote)); XCTAssertTrue(d.hasSuffix(ProcessCatalogText.managedAction))
        XCTAssertEqual(ProcessCatalogText.findingDetail(.unknown, defaultAction: action), action)
        XCTAssertEqual(ProcessCatalogText.findingDetail(.lookalike(m, .location), defaultAction: action), action)
        XCTAssertNil(ProcessCatalogText.findingNote(.lookalike(m, .signer)))
        XCTAssertEqual(ProcessCatalogText.findingNote(known(m)), m.findingNote)
    }

    func testManagedNeverSuggestsQuitting() {
        let m = Self.fixture().entry(id: "crowdstrike")!
        let texts = [ProcessCatalogText.findingDetail(known(m), defaultAction: "Quit it or let it finish.")]
            + ProcessCatalogText.inspectorRows(m).flatMap { [$0.label, $0.value] }
        for t in texts { XCTAssertNil(t.range(of: "quit", options: .caseInsensitive), t) }
        XCTAssertTrue(ProcessCatalogText.inspectorRows(m).contains { $0.value.contains(ProcessCatalogText.managedLabel) })
    }

    func testQuitSentences() {
        XCTAssertEqual(ProcessExplanation.QuitSafety.safe.sentence, "Safe to quit. It starts again when it's needed.")
        XCTAssertEqual(ProcessExplanation.QuitSafety.relaunches.sentence, "macOS starts it again within seconds, so quitting it doesn't help.")
        XCTAssertEqual(ProcessExplanation.QuitSafety.avoid.sentence, "Quitting it interrupts something you'll notice, such as sound, sync or your display.")
        XCTAssertEqual(ProcessExplanation.QuitSafety.never.sentence, "Don't. It's part of macOS, and quitting it can log you out, freeze or restart the Mac.")
        XCTAssertEqual(ProcessExplanation.QuitSafety.app.sentence, "An app you opened. Quitting it is safe; save your work first.")
        let rows = ProcessCatalogText.inspectorRows(Self.entry("x", quit: .relaunches, whatToDo: "Restart the Mac."))
        XCTAssertEqual(rows.map(\.label), ["Maker", "Usually busy when", "Quitting it", "If it misbehaves"])
        let bare = ProcessExplanation(id: "y", title: "Y", summary: "Y.", maker: .apple, quit: .safe, findingNote: "Y.", names: ["y"], groundedIn: "x-man-page://1/y")
        XCTAssertEqual(ProcessCatalogText.inspectorRows(bare).map(\.label), ["Maker", "Quitting it"], "rows without a value are left out")
    }

    func testTooltip() {
        let c = Self.fixture()
        var s = AnalyzerTests().proc("mdworker_shared", path: Self.mdworkerPath, pid: 5)
        let m = c.lookup(name: s.name, path: s.path, signature: nil)
        XCTAssertEqual(ProcessCatalogText.rowTooltip(m, s).components(separatedBy: "\n"), ["Title mdworker — Summary of mdworker.", Self.mdworkerPath])
        s.path = "/Users/x/Downloads/mdworker_shared"
        XCTAssertEqual(ProcessCatalogText.rowTooltip(c.lookup(name: s.name, path: s.path, signature: nil), s), s.path, "a lookalike gets today's path-only text")
        var r = AnalyzerTests().proc("secret", path: "", pid: 6); r.restricted = true
        XCTAssertEqual(ProcessCatalogText.rowTooltip(c.lookup(name: r.name, path: r.path, signature: nil), r), ProcessCatalogText.restricted)
        let f = AnalyzerTests().proc("falcond", path: "/Library/CS/falcond", pid: 7)
        XCTAssertTrue(ProcessCatalogText.rowTooltip(c.lookup(name: f.name, path: f.path, signature: nil), f).hasSuffix("\n" + ProcessCatalogText.managedLabel))
    }

    func testTooltipNameOnlySuffix() {
        var s = AnalyzerTests().proc("coreaudiod", path: "", pid: 8); s.restricted = true
        let t = ProcessCatalogText.rowTooltip(Self.fixture().lookup(name: s.name, path: s.path, signature: nil), s)
        XCTAssertEqual(t, "Title coreaudiod — Summary of coreaudiod. (matched by name only)\n" + ProcessCatalogText.restricted)
    }

    func testLookalikeSentence() {
        let e = Self.fixture().entry(id: "mdworker")!
        XCTAssertEqual(ProcessCatalogText.lookalikeSentence(e, reason: .location, path: NSHomeDirectory() + "/Downloads/mdworker"),
                       "Named like macOS's mdworker_shared (Title mdworker), but it isn't where macOS keeps it: ~/Downloads/mdworker.")
        XCTAssertTrue(ProcessCatalogText.lookalikeSentence(e, reason: .location, path: "/usr/local/bin/mdworker").hasSuffix(": /usr/local/bin/mdworker."))
        XCTAssertEqual(ProcessCatalogText.lookalikeSentence(e, reason: .signer, path: "/opt/x/worker"),
                       "Named like macOS's mdworker_shared (Title mdworker), but it isn't signed by Apple: /opt/x/worker.")
    }

    /// A re-signed binary at the vendor's own path is described by its signer, not its location, and an entry without a
    /// name key isn't named twice.
    func testLookalikeSentenceSigner() {
        let c = Self.fixture()
        let m = c.lookup(name: "Google Chrome", path: Self.chromeMain, signature: Self.sig(team: "WRONGTEAM"))
        guard case .lookalike(let e, let r) = m else { return XCTFail("expected a lookalike, got \(m)") }
        XCTAssertEqual(r, .signer)
        XCTAssertEqual(ProcessCatalogText.lookalikeSentence(e, reason: r, path: Self.chromeMain),
                       "Named like Google's Title chrome, but it isn't signed by Google: \(Self.chromeMain).")
    }

    /// FlightDeck's own PID is FlightDeck wherever it runs from; any other PID goes through the lookalike guard.
    func testOwnProcessIsKnown() {
        let c = ProcessCatalog.shared
        let odd = NSHomeDirectory() + "/Downloads/FlightDeck.app/Contents/MacOS/FlightDeck"
        let me = c.lookup(pid: getpid(), name: "FlightDeck", path: odd, signature: nil)
        XCTAssertEqual(me.known?.id, "flightdeck"); XCTAssertEqual(verified(me), true)
        XCTAssertTrue(isLookalike(c.lookup(pid: getpid() + 1, name: "FlightDeck", path: odd, signature: nil)))
    }

    /// Another PID running FlightDeck's own executable (--mcp, the Chrome native host) is FlightDeck too.
    func testOwnExecutableIsKnown() {
        let c = ProcessCatalog.shared
        let odd = NSHomeDirectory() + "/Downloads/FlightDeck.app/Contents/MacOS/FlightDeck"
        let mcp = c.lookup(pid: getpid() + 1, name: "FlightDeck", path: odd, signature: nil, ownExecutable: odd)
        XCTAssertEqual(mcp.known?.id, "flightdeck"); XCTAssertEqual(verified(mcp), true)
        XCTAssertTrue(isLookalike(c.lookup(pid: getpid() + 1, name: "FlightDeck", path: odd, signature: nil, ownExecutable: "/elsewhere/FlightDeck")))
    }

    /// Process paths keep /private (/private/tmp/...), so FlightDeck's own executable is resolved the same way, with
    /// realpath, and a symlinked path to it still counts. URL.resolvingSymlinksInPath would strip /private and miss.
    func testOwnExecutableUnderPrivateTmp() throws {
        let dir = "/tmp/fd-own-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let exe = dir + "/FlightDeck"
        XCTAssertTrue(FileManager.default.createFile(atPath: exe, contents: Data()))
        let own = ProcessCatalog.realPath(exe)
        XCTAssertEqual(own, "/private" + exe)
        XCTAssertEqual(ProcessCatalog.ownExecutable(exe), "/private" + exe, "the app's own executable keeps /private, as process paths do")
        let c = ProcessCatalog.shared
        let m = c.lookup(pid: getpid() + 1, name: "FlightDeck", path: "/private" + exe, signature: nil, ownExecutable: own)
        XCTAssertEqual(m.known?.id, "flightdeck"); XCTAssertEqual(verified(m), true)
        try FileManager.default.createDirectory(atPath: dir + "/bin", withIntermediateDirectories: true)
        let link = dir + "/bin/FlightDeck"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: exe)
        XCTAssertEqual(c.lookup(pid: getpid() + 1, name: "FlightDeck", path: link, signature: nil, ownExecutable: own).known?.id, "flightdeck")
    }

    /// A name match outside the vendor's folders is vouched for by a valid signature from the vendor's team.
    func testVendorNameVouchedForBySignature() {
        let c = ProcessCatalog.shared
        let path = NSHomeDirectory() + "/Applications/iTerm.app/Contents/MacOS/iTerm2"
        let ok = c.lookup(name: "iTerm2", path: path, signature: Self.sig(team: "H7V7XYVQ7D"))
        XCTAssertEqual(ok.known?.id, "dev-iterm2"); XCTAssertEqual(verified(ok), true)
        XCTAssertEqual(reason(c.lookup(name: "iTerm2", path: path, signature: Self.sig(team: "WRONGTEAM"))), .signer)
        XCTAssertEqual(reason(c.lookup(name: "iTerm2", path: path, signature: Self.sig())), .signer)
        XCTAssertEqual(reason(c.lookup(name: "iTerm2", path: path, signature: Self.sig(valid: false, team: "H7V7XYVQ7D"))), .location)
        XCTAssertEqual(reason(c.lookup(name: "iTerm2", path: path, signature: nil)), .location)
    }

    /// Anyone can put a vendor's team ID in the OU of a self-signed certificate, so only a team ID on an Apple-issued
    /// certificate vouches for a name or bundle-ID match outside the vendor's folders.
    func testSelfSignedTeamDoesNotVouch() {
        let c = ProcessCatalog.shared
        let path = NSHomeDirectory() + "/Applications/iTerm.app/Contents/MacOS/iTerm2"
        XCTAssertEqual(reason(c.lookup(name: "iTerm2", path: path, signature: Self.sig(team: "H7V7XYVQ7D", anchored: false))), .location)
        XCTAssertEqual(verified(c.lookup(name: "iTerm2", path: path, signature: Self.sig(team: "H7V7XYVQ7D", anchored: true))), true)
        let f = Self.fixture()
        let fake = f.lookup(name: "chrome", path: "/opt/x/chrome", signature: Self.sig(team: "EQHXZ8M8AV", anchored: false, id: "com.google.Chrome"))
        XCTAssertEqual(reason(fake), .signer)
        XCTAssertEqual(id(f.lookup(name: "chrome", path: "/opt/x/chrome", signature: Self.sig(team: "EQHXZ8M8AV", anchored: true, id: "com.google.Chrome"))), "chrome")
    }

    func testKnownFactsLaunchedByStartupItem() {
        let s = AnalyzerTests().proc("agent", path: "/Library/Vendor/agent", pid: 9)
        let job = StartupItem(label: "com.vendor.agent", path: "/Library/LaunchAgents/com.vendor.agent.plist", program: "/Library/Vendor/agent",
                              kind: "Launch Agent (All Users)", runAtLoad: true, keepAlive: true, disabled: false, loaded: true, vendor: "Vendor")
        let l = ProcessFacts.lines(s, signature: Self.sig(team: "ABCDE12345"), ancestry: [(9, "agent"), (1, "launchd")], startupItems: [job])
        XCTAssertEqual(l.map(\.label), ["Signer", "Team", "Launched by", "Parent", "Description"])
        XCTAssertEqual(l[2].value, "com.vendor.agent (Launch Agent (All Users))")
        XCTAssertEqual(l[3].value, "launchd (1)")
        XCTAssertEqual(l.last?.value, ProcessCatalogText.noDescription)
    }

    /// With no launchd job for its path, the launcher is the parent from the ancestry.
    func testKnownFactsFallBackToParent() {
        let a = AnalyzerTests().proc("Thing", path: "/Applications/Thing.app/Contents/MacOS/Thing", pid: 10)
        let l = ProcessFacts.lines(a, signature: nil, ancestry: [(10, "Thing"), (1, "launchd")], startupItems: [])
        XCTAssertEqual(l.map(\.label), ["App", "Launched by", "Description"])
        XCTAssertEqual(l[0].value, "Thing"); XCTAssertEqual(l[1].value, "parent launchd (1)")
        XCTAssertEqual(l.last?.value, ProcessCatalogText.noDescription)
    }
}
