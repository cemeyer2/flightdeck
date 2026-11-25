// Checks on the shipped process catalog: every entry is well formed and cites checkable sources, no key is claimed
// twice (the cross-batch check when the part files are merged), today's explanations and the protected processes are
// covered, and lookups stay cheap enough to run per row per refresh.
import XCTest
@testable import FlightDeckCore

final class ProcessCatalogContentTests: XCTestCase {
    let catalog = ProcessCatalog.shared

    func testEveryEntryIsValid() {
        func trimmed(_ s: String) -> Bool { s == s.trimmingCharacters(in: .whitespacesAndNewlines) }
        for e in catalog.entries {
            let texts = [e.id, e.title, e.summary, e.findingNote, e.groundedIn] + [e.busyWhen, e.whatToDo].compactMap { $0 }
            for t in texts { XCTAssertFalse(t.isEmpty, e.id); XCTAssertTrue(trimmed(t), "\(e.id): whitespace around “\(t)”") }
            XCTAssertLessThanOrEqual(e.title.count, 60, e.id)
            XCTAssertLessThanOrEqual(e.summary.count, 280, e.id)
            XCTAssertLessThanOrEqual(e.findingNote.count, 160, e.id)
            XCTAssertFalse((e.names + e.namePrefixes + e.paths + e.pathPrefixes + e.bundleIDs).isEmpty, "\(e.id) has no match key")
            for p in e.paths + e.pathPrefixes { XCTAssertTrue(p.hasPrefix("/"), "\(e.id): \(p)") }
            if case .vendor(let v) = e.maker {
                XCTAssertFalse(v.isEmpty, e.id)
                if !e.bundleIDs.isEmpty { XCTAssertFalse(e.teamIDs.isEmpty, "\(e.id): a bundle ID key needs team IDs") }
                if !(e.names + e.namePrefixes).isEmpty {
                    XCTAssertFalse((e.paths + e.pathPrefixes).isEmpty, "\(e.id): vendor name keys need the vendor's own locations")
                }
            }
            for src in e.groundedIn.components(separatedBy: "; ") {
                guard let u = URL(string: src), let scheme = u.scheme else { XCTFail("\(e.id): unparseable source \(src)"); continue }
                XCTAssertTrue(["https", "x-man-page", "file"].contains(scheme), "\(e.id): \(src)")
                if scheme == "file" { XCTAssertTrue(src.hasPrefix("file:///"), "\(e.id): \(src) must be absolute") }
            }
        }
    }

    /// Corporate security and device-management entries (E2) never suggest quitting and always say what to do instead.
    func testManagedEntries() {
        for e in catalog.entries where e.managed {
            XCTAssertFalse(e.isApple, e.id)
            XCTAssertEqual(e.quit, .avoid, e.id)
            XCTAssertNotNil(e.whatToDo, e.id)
            for t in [e.summary, e.whatToDo ?? "", e.findingNote] {
                XCTAssertNil(t.range(of: "quit", options: .caseInsensitive), "\(e.id): \(t)")
            }
        }
    }

    func testNoDuplicates() {
        func dupes(_ keys: [String]) -> [String] { Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.map(\.key) }
        let es = catalog.entries
        XCTAssertEqual(dupes(es.map(\.id)), [], "ids")
        XCTAssertEqual(dupes(es.flatMap(\.names)), [], "names")
        XCTAssertEqual(dupes(es.flatMap(\.paths)), [], "paths")
        XCTAssertEqual(dupes(es.flatMap(\.bundleIDs)), [], "bundle IDs")
        XCTAssertEqual(dupes(es.flatMap(\.namePrefixes)), [], "name prefixes")
        XCTAssertEqual(dupes(es.flatMap(\.pathPrefixes)), [], "path prefixes")
        for e in es {
            for p in e.namePrefixes { for o in es where o.id != e.id { XCTAssertFalse(o.names.contains(p), "\(e.id)'s prefix \(p) is \(o.id)'s name") } }
            for p in e.pathPrefixes { for o in es where o.id != e.id { XCTAssertFalse(o.paths.contains(p), "\(e.id)'s prefix \(p) is \(o.id)'s path") } }
        }
    }

    /// Rows have no signature, so an Apple entry keyed by a path outside macOS's own folders would always read as a
    /// lookalike. Apple apps installed in /Applications are left out of the catalog for that reason.
    func testAppleEntriesKeyOnlyPlatformPaths() {
        for e in catalog.entries where e.isApple {
            for p in e.paths + e.pathPrefixes { XCTAssertTrue(Platform.isPlatformPath(p), "\(e.id): \(p)") }
        }
    }

    func testBatchesAreSmall() {
        XCTAssertEqual(ProcessCatalogParts.batches.map(\.number), Array(1...12))
        for b in ProcessCatalogParts.batches { XCTAssertLessThanOrEqual(b.entries.count, 100, b.area) }
    }

    /// Every name the old 13-row explanation table (before the catalog) explained still gets an explanation, except
    /// softwareupdate_download_service, which no longer exists on current macOS and so can't be grounded.
    func testLegacyKnownNamesResolve() {
        let apple = ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "backupd", "backupd-helper", "photoanalysisd",
                     "photolibraryd", "mediaanalysisd", "softwareupdated", "mobileassetd",
                     "kernel_task", "WindowServer", "bird", "cloudd", "fileproviderd", "nsurlsessiond", "XprotectService", "XProtect",
                     "syspolicyd", "trustd", "corespotlightd", "suggestd", "knowledge-agent", "coreaudiod", "launchd",
                     "com.apple.WebKit.WebContent"]
        for n in apple { XCTAssertNotNil(catalog.lookup(name: n, path: "", signature: nil).known, n) }
        let helpers = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/131.0.6778.86/Helpers/"
        for n in ["Google Chrome Helper", "Google Chrome Helper (Renderer)"] {
            XCTAssertNotNil(catalog.lookup(name: n, path: helpers + "\(n).app/Contents/MacOS/\(n)", signature: nil).known, n)
        }
    }

    /// Rules refuse to touch these, so the catalog must not call them safe to quit.
    func testProtectedNamesAreNotSafe() {
        for n in RuleEngine.protected {
            let e = catalog.lookup(name: n, path: "", signature: nil).known
            XCTAssertNotNil(e, n)
            XCTAssertNotEqual(e?.quit, .safe, n)
        }
    }

    /// Ordinary apps the user opened are safe to quit once their work is saved. FlightDeck itself stays `.avoid`
    /// (quitting it stops its monitoring, alerts and rules), as does Docker Desktop's bundle as a whole (its backend and
    /// VM run the containers); only Docker Desktop's own interface app is an ordinary app.
    func testOrdinaryAppsAreApp() {
        let apps = ["apps-zoom", "apps-1password", "browser-chrome", "browser-arc", "browser-firefox", "dev-iterm2", "dev-docker-desktop-app"]
        XCTAssertEqual(Set(catalog.entries.filter { $0.quit == .app }.map(\.id)), Set(apps))
        for id in apps { XCTAssertEqual(catalog.entry(id: id)?.isApple, false, id); XCTAssertEqual(catalog.entry(id: id)?.managed, false, id) }
        XCTAssertEqual(catalog.entry(id: "flightdeck")?.quit, .avoid)
        XCTAssertEqual(catalog.entry(id: "dev-docker-desktop")?.quit, .avoid)
        let ui = "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop"
        XCTAssertEqual(catalog.lookup(name: "Docker Desktop", path: ui, signature: nil).known?.id, "dev-docker-desktop-app")
        let vm = "/Applications/Docker.app/Contents/MacOS/com.docker.virtualization"
        XCTAssertEqual(catalog.lookup(name: "com.docker.virtualization", path: vm, signature: nil).known?.id, "dev-docker-desktop")
    }

    /// The thermal finding explains kernel_task by entry id.
    func testKernelTaskEntryExists() {
        XCTAssertNotNil(catalog.entry(id: "kernel-task"))
    }

    /// Rows look every process up on every refresh, so 10,000 lookups must stay cheap. A fixed mix of names and paths
    /// (catalog keys, their hidden-path and lookalike variants, and unknown processes) keeps the work the same on every
    /// machine; the bound is generous so a loaded runner or a sanitizer build doesn't fail it, while a regression to a
    /// linear scan with I/O still would.
    func testLookupPerformance() {
        var mix: [(String, String)] = []
        for e in catalog.entries {
            for n in e.names { mix += [(n, ""), (n, "/Users/x/Downloads/" + n)] }
            for p in e.paths { mix.append(((p as NSString).lastPathComponent, p)) }
            for p in e.pathPrefixes { mix.append(("helper", p + "Contents/MacOS/helper")) }
            for p in e.namePrefixes { mix.append((p + "Worker", "")) }
        }
        mix += (0..<200).map { ("unknown\($0)", "/opt/tool/bin/unknown\($0)") }
        var hits = 0
        let t = Date()
        for i in 0..<10_000 { let (n, p) = mix[i % mix.count]; if catalog.lookup(name: n, path: p, signature: nil).known != nil { hits += 1 } }
        let ms = Date().timeIntervalSince(t) * 1000
        print("COST catalog 10k lookups", String(format: "%.1f ms", ms), "(\(hits) known)")
        XCTAssertGreaterThan(hits, 0)
        XCTAssertLessThan(ms, 1000)
    }

    /// Writes one Markdown review digest per batch, plus every cited source (one per line, for checking), to
    /// FLIGHTDECK_CATALOG_REVIEW_DIR. Skipped unless that variable is set.
    func testWriteReviewDigest() throws {
        guard let path = ProcessInfo.processInfo.environment["FLIGHTDECK_CATALOG_REVIEW_DIR"] else {
            throw XCTSkip("set FLIGHTDECK_CATALOG_REVIEW_DIR to write the review digests")
        }
        let dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func slug(_ s: String) -> String {
            s.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
                .split(separator: "-").joined(separator: "-")
        }
        var sources = Set<String>()
        for b in ProcessCatalogParts.batches {
            var md = "# Batch \(b.number)/12: \(b.area) (PENDING USER REVIEW, \(b.entries.count) entries)\n"
            for e in b.entries {
                let keys = [("names", e.names), ("name prefixes", e.namePrefixes), ("paths", e.paths), ("path prefixes", e.pathPrefixes),
                            ("bundle IDs", e.bundleIDs), ("team IDs", e.teamIDs)]
                    .filter { !$0.1.isEmpty }.map { "\($0.0): " + $0.1.map { "`\($0)`" }.joined(separator: ", ") }
                let srcs = e.groundedIn.components(separatedBy: "; ")
                sources.formUnion(srcs)
                md += """

                ## \(e.title) (`\(e.id)`)

                - **Summary:** \(e.summary)
                - **Maker:** \(e.makerName)\(e.managed ? " (managed by your organisation)" : "")
                - **Usually busy when:** \(e.busyWhen ?? "—")
                - **Quitting it:** \(e.quit.rawValue): \(e.quit.sentence)
                - **What to do:** \(e.whatToDo ?? "—")
                - **Finding note:** \(e.findingNote)
                - **Match keys:** \(keys.joined(separator: "; "))
                - **Sources:** \(srcs.map { "[\($0)](\($0))" }.joined(separator: ", "))

                """
            }
            try md.write(to: dir.appendingPathComponent(String(format: "batch-%02d-%@.md", b.number, slug(b.area))), atomically: true, encoding: .utf8)
        }
        try (sources.sorted().joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("sources.txt"), atomically: true, encoding: .utf8)
    }
}
