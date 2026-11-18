import Foundation

// Decides exactly what a space-hog cleanup would move to the Trash, and moves it. Every path is checked twice, once when
// the plan is made and again just before it moves, against the category it claims to belong to. FlightDeck never
// deletes anything itself; it only moves items to the Trash (FileManager.trashItem), where the user can still put them
// back. Paths outside the home folder and /Applications, SIP-protected files and anything a category doesn't own are
// refused.

/// What a cleanup would move to the Trash.
public struct CleanupPlan: Sendable {
    public var category: SpaceHogCategory
    public var items: [HogItem]
    /// Items that were measured but won't be moved, with why.
    public var refused: [(path: String, reason: String)]
    /// Sum of the items' known sizes. Items whose size couldn't be read add nothing here; `unknownSizes` counts them.
    public var total: UInt64 { items.reduce(0) { $0 + ($1.size.bytes ?? 0) } }
    public var unknownSizes: Int { items.filter { $0.size.bytes == nil }.count }
}

/// What happened when a plan ran.
public struct CleanupOutcome: Sendable {
    public var moved: [HogItem] = []
    public var failed: [(path: String, reason: String)] = []
    public var bytesMoved: UInt64 { moved.reduce(0) { $0 + ($1.size.bytes ?? 0) } }
    public init() {}
}

public enum CleanupPlanner {
    /// System locations nothing in FlightDeck may ever touch, even if a category somehow pointed there.
    static let protectedPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private", "/etc", "/var", "/dev", "/cores",
                                    "/Library", "/opt", "/Volumes", "/Network"]

    /// The plan for a measured category: for "trash contents" every item in its folders; for "older than N days" the
    /// items added before the cutoff; for "trash items" the matched bundles. Categories with any other cleanup have
    /// an empty plan.
    public static func plan(_ r: HogResult, home: String = NSHomeDirectory(), now: Date = Date()) -> CleanupPlan {
        var items: [HogItem] = [], refused: [(String, String)] = []
        let cutoff: Date?
        switch r.category.cleanup {
        case .trashContents, .trashItems: cutoff = nil
        case .trashOlderThan(let days): cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        default: return CleanupPlan(category: r.category, items: [], refused: [])
        }
        for loc in r.locations {
            for item in loc.items {
                if let cutoff {
                    // Unknown date: not provably old, so it stays.
                    guard let d = item.added, d < cutoff else { continue }
                }
                if let why = refusal(item.path, for: r.category, home: home) { refused.append((item.path, why)) } else { items.append(item) }
            }
        }
        return CleanupPlan(category: r.category, items: items, refused: refused)
    }

    /// Why `path` may not be moved to the Trash by `category`'s cleanup, or nil if it may. Pure path logic, plus an
    /// lstat for the SIP "restricted" flag and a check that no folder on the way is a symbolic link leading elsewhere.
    public static func refusal(_ path: String, for c: SpaceHogCategory, home: String) -> String? {
        guard c.cleanup.movesToTrash else { return "This category's cleanup doesn't move files." }
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return "Not a plain absolute path." }
        let p = (path as NSString).standardizingPath
        let parent = (p as NSString).deletingLastPathComponent
        let homeStd = (home as NSString).standardizingPath
        let inHome = PathTemplate.isWithin(p, homeStd) && p != homeStd
        let inApps = PathTemplate.isWithin(p, "/Applications") && p != "/Applications"
        guard inHome || inApps else { return "Outside your home folder and /Applications." }
        if !inHome, protectedPrefixes.contains(where: { PathTemplate.isWithin(p, $0) }) { return "A system location." }
        // Must be directly inside one of the category's own folders (or match its wildcard), never one of its excludes.
        let excluded = c.excludes.map { PathTemplate.expandHome($0, home: home) }
        if excluded.contains(where: { PathTemplate.isWithin(p, $0) }) { return "Belongs to another category." }
        let owned = c.paths.contains { t in
            let full = PathTemplate.expandHome(t, home: home)
            if t.contains("*") {
                return parent == (full as NSString).deletingLastPathComponent
                    && PathTemplate.matches((p as NSString).lastPathComponent, pattern: (full as NSString).lastPathComponent)
            }
            return parent == full
        }
        guard owned else { return "Not inside this category's folders." }
        // A symlinked folder on the way could make "inside ~/Library/Caches" mean somewhere else entirely.
        let realParent = (parent as NSString).resolvingSymlinksInPath
        let realHome = (homeStd as NSString).resolvingSymlinksInPath
        guard PathTemplate.isWithin(realParent, realHome) || PathTemplate.isWithin(realParent, "/Applications") else {
            return "Its folder is a link to somewhere else."
        }
        var st = stat()
        if lstat(p, &st) == 0, st.st_flags & UInt32(SF_RESTRICTED) != 0 { return "Protected by macOS (System Integrity Protection)." }
        return nil
    }

    /// Moves the plan's items to the Trash, re-checking each one first. `mover` does the move; the app passes
    /// FileManager.trashItem (the default) and tests pass a closure that moves into a temporary folder, so tests never
    /// touch the real Trash. `cancelled` is polled between items.
    public static func execute(_ plan: CleanupPlan, home: String = NSHomeDirectory(),
                               mover: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                               cancelled: () -> Bool = { false }) -> CleanupOutcome {
        var out = CleanupOutcome()
        for item in plan.items {
            if cancelled() { break }
            if let why = refusal(item.path, for: plan.category, home: home) { out.failed.append((item.path, why)); continue }
            var st = stat()
            guard lstat(item.path, &st) == 0 else { out.failed.append((item.path, "No longer there.")); continue }
            do { try mover(URL(fileURLWithPath: item.path)); out.moved.append(item) }
            catch { out.failed.append((item.path, (error as NSError).localizedDescription)) }
        }
        return out
    }
}
