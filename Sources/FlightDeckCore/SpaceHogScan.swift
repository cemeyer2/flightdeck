import Foundation

// Measures the space-hog categories. Only ever started by the user (Disk Space › Analyze): reading folders such as
// Downloads, Mail or Messages makes macOS ask for permission, and a refused folder is reported as not readable, never
// as empty. Runs synchronously on the caller's background thread and polls `cancelled` between items.

public enum SpaceHogScanner {
    /// Analyzes `categories` in order, handing each result to `result` as it finishes. `progress` gets the index of
    /// the category being measured. With `useTools`, simctl and brew are asked too (off in tests). Stops early when
    /// `cancelled` returns true; the category in flight is then dropped rather than reported half-measured.
    public static func analyze(_ categories: [SpaceHogCategory] = SpaceHogCategory.catalog,
                               home: String = NSHomeDirectory(), useTools: Bool = true,
                               progress: (Int) -> Void = { _ in }, result: (HogResult) -> Void,
                               cancelled: () -> Bool) {
        var cats = categories
        // Homebrew's cache can live elsewhere (HOMEBREW_CACHE); wherever it is, it belongs to the Homebrew row and is
        // excluded from App caches so it isn't counted twice.
        var brewNotes: [String] = []
        if useTools, cats.contains(where: { $0.id == "homebrew" }) {
            if let brew = DevTools.brewPath() {
                if let cache = DevTools.brewCache(brew) {
                    for i in cats.indices where cats[i].id == "homebrew" { cats[i].paths = [cache] }
                    for i in cats.indices where cats[i].id == "caches" { cats[i].excludes.append(cache) }
                    brewNotes.append("brew --cache: \(cache)")
                } else { brewNotes.append("brew --cache didn't answer; looked in the default location.") }
            } else { brewNotes.append("Homebrew isn't installed (no brew in /opt/homebrew or /usr/local).") }
        }
        for (i, c) in cats.enumerated() {
            if cancelled() { return }
            progress(i)
            guard var r = measure(c, home: home, cancelled: cancelled) else { return }
            if c.id == "homebrew" { r.notes += brewNotes }
            if useTools { r.notes += toolNotes(c) }
            result(r)
        }
    }

    /// Measures one category. Nil if cancelled.
    public static func measure(_ c: SpaceHogCategory, home: String, cancelled: () -> Bool) -> HogResult? {
        let excludes = Set(c.excludes.map { PathTemplate.expandHome($0, home: home) })
        var locations: [HogLocation] = []
        for template in c.paths {
            if template.contains("*") {
                // Bundles matched by a wildcard (an installer app, a VM, a Photos library) are each one item.
                for p in PathTemplate.resolve(template, home: home) {
                    guard let s = DirectorySizer.size(of: p, cancelled: cancelled) else { return nil }
                    locations.append(HogLocation(path: p, size: s, items: [HogItem(path: p, size: s, added: addedDate(p))]))
                }
            } else {
                guard let loc = measureFolder(PathTemplate.expandHome(template, home: home), excludes: excludes, cancelled: cancelled) else { return nil }
                locations.append(loc)
            }
        }
        return HogResult(category: c, locations: locations)
    }

    /// A folder measured item by item (so the cleanup list and the total come from one walk), largest first.
    static func measureFolder(_ path: String, excludes: Set<String>, cancelled: () -> Bool) -> HogLocation? {
        var st = stat()
        if lstat(path, &st) != 0 {
            let s: SizeResult = errno == ENOENT || errno == ENOTDIR ? .missing : .notReadable(DirectorySizer.deniedReason)
            return HogLocation(path: path, size: s, items: [])
        }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            guard let s = DirectorySizer.size(of: path, cancelled: cancelled) else { return nil }
            return HogLocation(path: path, size: s, items: [HogItem(path: path, size: s, added: addedDate(path))])
        }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: path) } catch {
            let reason = DirectorySizer.isPermissionError(error) ? DirectorySizer.deniedReason : (error as NSError).localizedDescription
            return HogLocation(path: path, size: .notReadable(reason), items: [])
        }
        var items: [HogItem] = []
        var total: UInt64 = 0, unreadable = 0
        // .DS_Store and friends are Finder's bookkeeping, not something to list or clean.
        for name in names where name != ".DS_Store" && name != ".localized" {
            let p = (path as NSString).appendingPathComponent(name)
            if excludes.contains(p) { continue }
            guard let s = DirectorySizer.size(of: p, cancelled: cancelled) else { return nil }
            switch s {
            case .size(let b, let u): total += b; unreadable += u
            case .notReadable: unreadable += 1
            case .missing: continue   // vanished while we looked
            }
            items.append(HogItem(path: p, size: s, added: addedDate(p)))
        }
        items.sort { ($0.size.bytes ?? 0) > ($1.size.bytes ?? 0) }
        return HogLocation(path: path, size: .size(bytes: total, unreadable: unreadable), items: items)
    }

    /// Finder's "Date Added", else the modification date.
    static func addedDate(_ path: String) -> Date? {
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
        return v?.addedToDirectoryDate ?? v?.contentModificationDate
    }

    /// What simctl says about simulators and runtimes, as readable lines.
    static func toolNotes(_ c: SpaceHogCategory) -> [String] {
        guard c.id == "simDevices" || c.id == "simRuntimes" else { return [] }
        guard let simctl = DevTools.simctlPath() else { return ["simctl isn't available (Xcode isn't the selected developer directory)."] }
        if c.id == "simDevices" {
            guard let out = DevTools.run(simctl, ["list", "-j", "devices"], timeout: 30),
                  let devs = SimctlParse.devices(Data(out.output.utf8)) else { return ["simctl list didn't return a device list."] }
            let gone = devs.filter { !$0.isAvailable }.count
            return ["\(devs.count) simulators, \(gone) unavailable (their runtime is no longer installed)."]
        }
        guard let out = DevTools.run(simctl, ["runtime", "list", "-j"], timeout: 30),
              let rts = SimctlParse.runtimes(Data(out.output.utf8)) else { return ["simctl runtime list didn't return a list."] }
        if rts.isEmpty { return ["simctl reports no separately downloaded runtimes."] }
        return rts.map { r in
            let name = r.identifier.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            return "\(name)\(r.version.map { " (\($0))" } ?? ""): \(r.sizeBytes.map { Fmt.storage($0) } ?? "size not reported")"
        }
    }
}
