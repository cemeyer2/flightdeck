// Tests for the space-hog catalog, path expansion, the analysis and the cleanup planner. Everything runs against a
// fake home folder in a temporary directory, and "moving to the Trash" is a move into another temporary folder: no
// test touches the real home folder or the real Trash.
import XCTest
@testable import FlightDeckCore

final class SpaceHogTests: XCTestCase {
    var home = ""
    var fakeTrash = ""
    let fm = FileManager.default

    override func setUpWithError() throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("fd-hogs-\(UUID().uuidString)")
        home = base + "/home"; fakeTrash = base + "/trash"
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: fakeTrash, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(atPath: (home as NSString).deletingLastPathComponent) }

    @discardableResult func file(_ rel: String, bytes: Int = 10_000, date: Date? = nil) throws -> String {
        let p = home + "/" + rel
        try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: p))
        if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: p) }
        return p
    }
    /// Moves into the temporary "trash" instead of the user's real one.
    func mover(_ u: URL) throws { try fm.moveItem(at: u, to: URL(fileURLWithPath: fakeTrash).appendingPathComponent(UUID().uuidString)) }

    func testCatalogIsWellFormed() {
        let cats = SpaceHogCategory.catalog
        XCTAssertEqual(Set(cats.map(\.id)).count, cats.count, "ids are unique")
        for c in cats {
            XCTAssertFalse(c.paths.isEmpty, c.id); XCTAssertFalse(c.whatItIs.isEmpty, c.id); XCTAssertFalse(c.ifRemoved.isEmpty, c.id)
            // Anything that moves files must only point into the home folder or /Applications.
            if c.cleanup.movesToTrash {
                for t in c.paths { XCTAssertTrue(t.hasPrefix("~/") || t.hasPrefix("/Applications/"), "\(c.id): \(t)") }
            }
            // Your own data is never offered for removal, except old downloads, which are listed for review first.
            if c.safety == .yourData && c.cleanup.movesToTrash { XCTAssertEqual(c.id, "downloads") }
        }
        // App caches exclude the folders the more specific categories own, so nothing counts twice.
        let caches = SpaceHogCategory.named("caches")!
        for t in SpaceHogCategory.named("devCaches")!.paths + SpaceHogCategory.named("homebrew")!.paths where t.hasPrefix("~/Library/Caches/") {
            XCTAssertTrue(caches.excludes.contains(t), t)
        }
    }

    func testPathExpansion() throws {
        XCTAssertEqual(PathTemplate.expandHome("~/Library/Caches", home: "/Users/me"), "/Users/me/Library/Caches")
        XCTAssertEqual(PathTemplate.expandHome("~", home: "/Users/me"), "/Users/me")
        XCTAssertEqual(PathTemplate.expandHome("/Applications/X.app", home: "/Users/me"), "/Applications/X.app")
        XCTAssertEqual(PathTemplate.expandHome("~/a/../b//c", home: "/Users/me"), "/Users/me/b/c")
        XCTAssertEqual(PathTemplate.expandHome("~other/x", home: "/Users/me"), "~other/x")   // only our own ~
        XCTAssertTrue(PathTemplate.matches("Install macOS Sonoma.app", pattern: "Install macOS*.app"))
        XCTAssertFalse(PathTemplate.matches("Install macOS Sonoma.app.zip", pattern: "Install macOS*.app"))
        XCTAssertTrue(PathTemplate.matches("a.pvm", pattern: "*.pvm"))
        XCTAssertTrue(PathTemplate.matches("xay", pattern: "x*a*y"))
        XCTAssertFalse(PathTemplate.matches("xy", pattern: "x*a*y"))
        XCTAssertTrue(PathTemplate.isWithin("/a/b/c", "/a/b")); XCTAssertFalse(PathTemplate.isWithin("/a/bc", "/a/b"))
        try fm.createDirectory(atPath: home + "/Parallels/Win.pvm", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/Parallels/Linux.pvm", withIntermediateDirectories: true)
        try file("Parallels/notes.txt")
        XCTAssertEqual(PathTemplate.resolve("~/Parallels/*.pvm", home: home), [home + "/Parallels/Linux.pvm", home + "/Parallels/Win.pvm"])
        XCTAssertEqual(PathTemplate.resolve("~/Nope/*.pvm", home: home), [])
        XCTAssertEqual(PathTemplate.resolve("~/Parallels", home: home), [home + "/Parallels"])
    }

    func testSizingMissingAndPartial() throws {
        try file("Library/Caches/com.app/a", bytes: 50_000)
        try file("Library/Caches/com.app/b", bytes: 50_000)
        let s = try XCTUnwrap(DirectorySizer.size(of: home + "/Library/Caches"))
        XCTAssertGreaterThanOrEqual(s.bytes ?? 0, 100_000)   // allocated, so at least the logical size
        XCTAssertEqual(DirectorySizer.size(of: home + "/missing"), .missing)
        // Cancellation is polled every 500 files.
        for i in 0..<600 { try file("Many/f\(i)", bytes: 1) }
        XCTAssertNil(DirectorySizer.size(of: home + "/Many", cancelled: { true }))
        XCTAssertNotNil(DirectorySizer.size(of: home + "/Many", cancelled: { false }))
        // A folder we may not list is "not readable", never 0 (chmod stands in for a privacy denial).
        let locked = home + "/Locked"
        try fm.createDirectory(atPath: locked, withIntermediateDirectories: true)
        try file("Locked/x")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        guard case .notReadable = try XCTUnwrap(DirectorySizer.size(of: locked)) else { return XCTFail("expected not readable") }
    }

    func testMeasureExcludesAndPlansContents() throws {
        try file("Library/Caches/com.app/data", bytes: 40_000)
        try file("Library/Caches/Homebrew/bottle.tar.gz", bytes: 90_000)
        try file("Library/Caches/.DS_Store", bytes: 10)
        let r = try XCTUnwrap(SpaceHogScanner.measure(SpaceHogCategory.named("caches")!, home: home, cancelled: { false }))
        XCTAssertEqual(r.locations.first?.items.map(\.name), ["com.app"], "Homebrew is excluded, .DS_Store ignored")
        let plan = CleanupPlanner.plan(r, home: home)
        XCTAssertEqual(plan.items.map(\.path), [home + "/Library/Caches/com.app"])
        XCTAssertEqual(plan.total, r.total)
        let out = CleanupPlanner.execute(plan, home: home, mover: mover)
        XCTAssertEqual(out.moved.count, 1); XCTAssertTrue(out.failed.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: home + "/Library/Caches/com.app"))
        XCTAssertTrue(fm.fileExists(atPath: home + "/Library/Caches"), "the folder itself stays")
        XCTAssertTrue(fm.fileExists(atPath: home + "/Library/Caches/Homebrew/bottle.tar.gz"), "excluded folder untouched")
        // Absent categories are absent, not 0 B.
        let none = try XCTUnwrap(SpaceHogScanner.measure(SpaceHogCategory.named("derivedData")!, home: home, cancelled: { false }))
        XCTAssertTrue(none.isAbsent); XCTAssertNil(none.total)
    }

    func testOldDownloadsOnly() throws {
        let now = Date()
        try file("Downloads/old.dmg", date: now.addingTimeInterval(-200 * 86_400))
        try file("Downloads/new.zip", date: now.addingTimeInterval(-2 * 86_400))
        var r = try XCTUnwrap(SpaceHogScanner.measure(SpaceHogCategory.named("downloads")!, home: home, cancelled: { false }))
        // Finder's Date Added isn't set for files created by the test, so the modification date decides; pin both.
        for i in r.locations[0].items.indices {
            r.locations[0].items[i].added = r.locations[0].items[i].name == "old.dmg" ? now.addingTimeInterval(-200 * 86_400) : now.addingTimeInterval(-2 * 86_400)
        }
        XCTAssertEqual(CleanupPlanner.plan(r, home: home, now: now).items.map(\.name), ["old.dmg"])
        r.locations[0].items[0].added = nil; r.locations[0].items[1].added = nil
        XCTAssertTrue(CleanupPlanner.plan(r, home: home, now: now).items.isEmpty, "unknown dates are not old")
    }

    func testRefusesPathsOutsideItsCategory() throws {
        let caches = SpaceHogCategory.named("caches")!
        XCTAssertNil(CleanupPlanner.refusal(home + "/Library/Caches/com.app", for: caches, home: home))
        for bad in ["/etc/hosts", "/System/Library/Caches/x", "/Library/Caches/x", home + "/Documents/thesis.pdf",
                    home + "/Library/Caches", home + "/Library/Caches/com.app/deeper", home + "/Library/Caches/../Mail",
                    home + "/Library/Caches/Homebrew", home, "relative/path", "/Applications/Safari.app"] {
            XCTAssertNotNil(CleanupPlanner.refusal(bad, for: caches, home: home), bad)
        }
        // Categories that don't move files refuse everything, even their own paths.
        let photos = SpaceHogCategory.named("photos")!
        XCTAssertNotNil(CleanupPlanner.refusal(home + "/Pictures/Photos Library.photoslibrary", for: photos, home: home))
        // Installers: only the matching bundles in /Applications.
        let inst = SpaceHogCategory.named("installers")!
        XCTAssertNil(CleanupPlanner.refusal("/Applications/Install macOS Sequoia.app", for: inst, home: home))
        XCTAssertNotNil(CleanupPlanner.refusal("/Applications/Xcode.app", for: inst, home: home))
        XCTAssertNotNil(CleanupPlanner.refusal("/Applications/Utilities/Install macOS Sequoia.app", for: inst, home: home))

        // A tampered plan is re-checked when it runs: the outside file survives.
        let outside = try file("Documents/keep.txt")
        try file("Library/Caches/ok/x")
        let r = try XCTUnwrap(SpaceHogScanner.measure(caches, home: home, cancelled: { false }))
        var plan = CleanupPlanner.plan(r, home: home)
        plan.items.append(HogItem(path: outside, size: .size(bytes: 1, unreadable: 0), added: nil))
        let out = CleanupPlanner.execute(plan, home: home, mover: mover)
        XCTAssertEqual(out.moved.map(\.name), ["ok"]); XCTAssertEqual(out.failed.map(\.path), [outside])
        XCTAssertTrue(fm.fileExists(atPath: outside))
    }

    func testSymlinkedFolderIsRefused() throws {
        let elsewhere = (home as NSString).deletingLastPathComponent + "/elsewhere"
        try fm.createDirectory(atPath: elsewhere + "/victim", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/Library", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/Library/Logs", withDestinationPath: elsewhere)
        XCTAssertNotNil(CleanupPlanner.refusal(home + "/Library/Logs/victim", for: SpaceHogCategory.named("logs")!, home: home))
    }
}
