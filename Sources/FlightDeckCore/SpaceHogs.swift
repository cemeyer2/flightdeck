import Foundation

// Disk Space › known space hogs: the places that usually fill a Mac, each with where it is, whether it's safe to
// remove and what happens if you do, plus the one cleanup FlightDeck offers for it (if any). The definitions are data
// so the wording and the paths can be tested; the texts themselves are in SpaceHogCatalog.swift.

/// One kind of space hog.
public struct SpaceHogCategory: Sendable, Identifiable, Hashable {
    /// How safe removing it is, from the user's point of view.
    public enum Safety: String, Sendable, Hashable {
        /// Rebuilt or re-downloaded automatically; nothing of yours is lost.
        case safe
        /// Nothing of yours is lost, but something gets slower or has to be re-fetched by hand.
        case safeWithCost
        /// Your own data: only you can decide. FlightDeck shows where it is and doesn't offer to remove it.
        case yourData

        public var label: String {
            switch self {
            case .safe: "Safe to remove"
            case .safeWithCost: "Safe, with a cost"
            case .yourData: "Your data: review it yourself"
            }
        }
    }

    /// The only cleanup FlightDeck offers for the category. Everything that moves files goes to the Trash; nothing is
    /// deleted permanently by FlightDeck itself (the official tools below do their own deleting, which is their job).
    public enum Cleanup: Sendable, Hashable {
        /// Move every item inside the category's folders to the Trash (the folders themselves stay).
        case trashContents
        /// Move items at the top of the folder that were added (or, failing that, modified) more than `days` ago.
        case trashOlderThan(days: Int)
        /// Move the matched items themselves to the Trash (e.g. an `Install macOS….app`).
        case trashItems
        /// Ask Finder to empty the Trash (Finder shows its own progress and honours locked items).
        case emptyTrashViaFinder
        /// `simctl delete unavailable`: removes simulators whose runtime is no longer installed.
        case simctlDeleteUnavailable
        /// `brew cleanup`, shown as a dry run (`brew cleanup -n`) first.
        case brewCleanup
        /// Nothing FlightDeck can safely do; `advice` says how to do it properly.
        case manual(advice: String)

        public var movesToTrash: Bool {
            switch self { case .trashContents, .trashOlderThan, .trashItems: true; default: false }
        }
    }

    public var id: String
    public var title: String
    /// SF Symbol name for the row.
    public var symbol: String
    /// Path templates: a leading `~` is the home folder, and the last component may contain `*` wildcards.
    public var paths: [String]
    /// Path templates skipped when sizing and cleaning (they belong to another category, so nothing counts twice).
    public var excludes: [String] = []
    public var whatItIs: String
    public var ifRemoved: String
    public var safety: Safety
    public var cleanup: Cleanup
    /// True when macOS's privacy protection usually guards the folder, so a prompt or "not readable" is expected.
    public var privacyProtected = false
}

/// Expands the catalog's path templates.
public enum PathTemplate {
    /// "~/Library/Caches" → "/Users/me/Library/Caches". Only a leading "~" or "~/" is expanded; the result is
    /// standardized (no "..", no double slashes).
    public static func expandHome(_ template: String, home: String) -> String {
        var p = template
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        return (p as NSString).standardizingPath
    }

    /// The existing paths a template stands for. Without a wildcard that's the path itself (if it exists); with one,
    /// the matching entries of its parent folder, sorted. Wildcards are only honoured in the last component.
    public static func resolve(_ template: String, home: String, fileManager fm: FileManager = .default) -> [String] {
        let full = expandHome(template, home: home)
        let last = (full as NSString).lastPathComponent
        guard last.contains("*") else { return fm.fileExists(atPath: full) ? [full] : [] }
        let parent = (full as NSString).deletingLastPathComponent
        guard let names = try? fm.contentsOfDirectory(atPath: parent) else { return [] }
        return names.filter { matches($0, pattern: last) }.sorted().map { (parent as NSString).appendingPathComponent($0) }
    }

    /// Shell-style matching where only `*` is special (any run of characters, including none).
    public static func matches(_ name: String, pattern: String) -> Bool {
        let parts = pattern.components(separatedBy: "*")
        guard parts.count > 1 else { return name == pattern }
        guard name.hasPrefix(parts[0]), name.count >= parts[0].count + parts[parts.count - 1].count else { return false }
        var rest = Substring(name.dropFirst(parts[0].count))
        for mid in parts.dropFirst().dropLast() where !mid.isEmpty {
            guard let r = rest.range(of: mid) else { return false }
            rest = rest[r.upperBound...]
        }
        return rest.hasSuffix(parts[parts.count - 1])
    }

    /// Whether `path` is `root` itself or inside it, comparing whole path components (so "/a/bc" isn't inside "/a/b").
    public static func isWithin(_ path: String, _ root: String) -> Bool {
        let p = (path as NSString).standardizingPath, r = (root as NSString).standardizingPath
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}
