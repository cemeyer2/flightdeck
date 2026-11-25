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
            entry("chrome", maker: .vendor("Google"), quit: .safe, pathPrefixes: ["/Applications/Google Chrome.app/"],
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

    static func sig(apple: Bool = false, valid: Bool = true, team: String? = nil, id: String? = nil) -> ProcessDetails.Signature {
        ProcessDetails.Signature(identifier: id, teamID: team, authority: [], isApple: apple, valid: valid, hardenedRuntime: false)
    }

    func id(_ m: ProcessMatch) -> String? { m.known?.id }
    func key(_ m: ProcessMatch) -> MatchKey? { if case .known(_, let k, _) = m { return k }; return nil }
    func verified(_ m: ProcessMatch) -> Bool? { if case .known(_, _, let v) = m { return v }; return nil }
    func isLookalike(_ m: ProcessMatch) -> Bool { if case .lookalike = m { return true }; return false }

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
        XCTAssertTrue(isLookalike(c.lookup(name: "Google Chrome", path: Self.chromeMain, signature: Self.sig(team: "WRONGTEAM"))))
    }

    /// A vendor's name somewhere odd is not the vendor's program.
    func testVendorNameAtOddPathIsLookalike() {
        let c = Self.fixture()
        XCTAssertTrue(isLookalike(c.lookup(name: "Dropbox", path: "/Users/x/Downloads/Dropbox", signature: nil)))
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
}
