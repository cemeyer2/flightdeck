import Foundation

// Fast on-disk sizing for the space-hog analysis. Sizes are allocated bytes (`totalFileAllocatedSizeKey`: what the
// file really occupies, so sparse disk images like Docker.raw count what they use, not their nominal size), prefetched
// by the enumerator so each file costs one getattrlist rather than a separate stat. Hard links are counted once per
// link, as Finder's Get Info does. Runs on the caller's (background) thread.

/// The size of one file or folder tree.
public enum SizeResult: Sendable, Hashable {
    /// `bytes` allocated; `unreadable` items inside couldn't be read, so with unreadable > 0 the size is a lower bound.
    case size(bytes: UInt64, unreadable: Int)
    /// macOS refused to let FlightDeck read it (privacy protection or permissions). Never shown as 0.
    case notReadable(String)
    /// Nothing at that path.
    case missing

    public var bytes: UInt64? { if case .size(let b, _) = self { return b }; return nil }
}

public enum DirectorySizer {
    static let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]

    /// Whether an error means "not allowed", as opposed to "gone". TCC denials surface as EPERM, plain permissions as
    /// EACCES; Foundation wraps either as NSFileReadNoPermissionError.
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) { return true }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(u) }
        return false
    }

    static let deniedReason = "macOS didn't allow access (System Settings › Privacy & Security › Full Disk Access or Files & Folders)"

    /// Sizes `path` (a file, or a folder and everything in it). Symbolic links are sized as links, never followed, so a
    /// link can't pull in a tree that lives elsewhere. Returns nil if `cancelled` became true; it's polled every 500
    /// files, so cancelling a large tree takes effect within a few milliseconds. `progress`, if given, is called at the
    /// same cadence with the files seen and bytes counted so far in this tree, so a long scan can show it's moving.
    public static func size(of path: String, cancelled: () -> Bool = { false },
                            progress: (_ files: Int, _ bytes: UInt64) -> Void = { _, _ in }) -> SizeResult? {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        // lstat rather than fileExists: it doesn't follow links, and its errno separates "not there" (ENOENT) from
        // "not allowed to look" (EPERM/EACCES), which must never read as missing.
        var st = stat()
        if lstat(path, &st) != 0 {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .notReadable(deniedReason)
        }
        let top = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .totalFileAllocatedSizeKey])
        if top?.isSymbolicLink == true || top?.isDirectory != true {
            return top.map { .size(bytes: UInt64($0.totalFileAllocatedSize ?? 0), unreadable: 0) } ?? .notReadable(deniedReason)
        }
        // Listing the top level first separates "denied" (a privacy prompt was refused or never answered) from a
        // folder that's merely empty, which the enumerator alone can't tell apart.
        do { _ = try fm.contentsOfDirectory(atPath: path) } catch {
            return isPermissionError(error) ? .notReadable(deniedReason) : .notReadable((error as NSError).localizedDescription)
        }
        let errors = Counter()
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                    errorHandler: { _, _ in errors.n += 1; return true }) else {
            return .notReadable("The folder couldn't be listed.")
        }
        var total: UInt64 = 0, n = 0
        for case let u as URL in e {
            n += 1
            if n % 500 == 0 {
                if cancelled() { return nil }
                progress(n, total)
            }
            total += UInt64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        progress(n, total)
        return .size(bytes: total, unreadable: errors.n)
    }

    /// The enumerator's error handler is a non-escaping callback on this thread; a class lets it count.
    private final class Counter { var n = 0 }
}

/// One thing inside a category location: an item of a cache folder, a download, an installer app.
public struct HogItem: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String { (path as NSString).lastPathComponent }
    public var size: SizeResult
    /// When it was added to its folder (Finder's "Date Added"), else its modification date; nil if neither is known.
    public var added: Date?
    public init(path: String, size: SizeResult, added: Date?) { self.path = path; self.size = size; self.added = added }
}

/// One folder (or bundle) of a category, measured.
public struct HogLocation: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var size: SizeResult
    /// What's inside, largest first, for folders (a bundle such as a .photoslibrary is one item, itself).
    public var items: [HogItem]
    public init(path: String, size: SizeResult, items: [HogItem]) { self.path = path; self.size = size; self.items = items }
}

/// A category after analysis.
public struct HogResult: Sendable, Identifiable {
    public var id: String { category.id }
    public var category: SpaceHogCategory
    public var locations: [HogLocation]
    /// Extra facts from the official tools (simulator counts, runtimes, brew's cache path), one per line.
    public var notes: [String] = []
    public init(category: SpaceHogCategory, locations: [HogLocation], notes: [String] = []) {
        self.category = category; self.locations = locations; self.notes = notes
    }

    /// Bytes across the readable locations; nil when none could be read (so "not readable" rather than 0).
    public var total: UInt64? {
        let sizes = locations.compactMap { $0.size.bytes }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
    /// Locations macOS wouldn't let FlightDeck read, with the reason.
    public var unreadable: [(path: String, reason: String)] {
        locations.compactMap { if case .notReadable(let r) = $0.size { return ($0.path, r) }; return nil }
    }
    /// True when any readable location had unreadable items inside, so `total` is a lower bound.
    public var isPartial: Bool {
        !unreadable.isEmpty || locations.contains { if case .size(_, let u) = $0.size { return u > 0 }; return false }
    }
    /// True when nothing of the category exists on this Mac.
    public var isAbsent: Bool { locations.isEmpty || locations.allSatisfy { $0.size == .missing } }
}
