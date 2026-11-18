import Foundation

// The Applications inventory, plus recursive size helpers shared with the Disk Usage tool. All functions do blocking
// file-system work and are called off the main thread by the UI's loaders.
/// One application bundle. `architectures` is "arm64", "x86_64", "Universal" or "—" (unknown, e.g. a script-based app).
/// `isAppStore` is detected by the Mac App Store receipt inside the bundle.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var bundleID: String
    public var version: String
    public var vendor: String
    public var architectures: String
    public var modified: Date?
    public var isSystem: Bool
    public var isAppStore: Bool
}

public enum InstalledApps {
    /// Top-level .app bundles in the standard Applications folders. Apps nested in subfolders (other than Utilities) are
    /// not found; duplicates by path are skipped.
    public static func scan() -> [InstalledApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "\(home)/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities"]
        var seen = Set<String>(); var out: [InstalledApp] = []
        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for f in items where f.hasSuffix(".app") {
                let path = "\(root)/\(f)"
                guard seen.insert(path).inserted, let b = Bundle(path: path) else { continue }
                let info = b.infoDictionary ?? [:]
                let id = b.bundleIdentifier ?? ""
                let archs = (b.executableArchitectures ?? []).compactMap { n -> String? in
                    switch n.intValue { case NSBundleExecutableArchitectureARM64: return "arm64"
                    case NSBundleExecutableArchitectureX86_64: return "x86_64"; default: return nil }
                }
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                out.append(InstalledApp(
                    name: (info["CFBundleDisplayName"] as? String) ?? (f as NSString).deletingPathExtension,
                    path: path, bundleID: id,
                    version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String ?? ""),
                    vendor: vendor(id), architectures: archs.isEmpty ? "—" : (archs.count > 1 ? "Universal" : archs[0]),
                    modified: attrs?[.modificationDate] as? Date, isSystem: path.hasPrefix("/System"),
                    isAppStore: FileManager.default.fileExists(atPath: "\(path)/Contents/_MASReceipt/receipt")))
            }
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func vendor(_ id: String) -> String {
        let p = id.split(separator: "."); return p.count >= 2 ? String(p[1]).capitalized : ""
    }

    /// Allocated size of a directory tree (expensive; call off-main).
    /// Uses the allocated size (blocks actually used on disk, including resource forks) so sparse and compressed files
    /// aren't over-counted. Unreadable entries are skipped by the error handler, so the result is a lower bound.
    public static func size(of path: String) -> UInt64 {
        let url = URL(fileURLWithPath: path)
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: UInt64 = 0
        for case let u as URL in e {
            total += UInt64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

/// One child of a directory in the Disk Usage tool, with its recursive allocated size in bytes.
public struct DirEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var size: UInt64
    public var isDirectory: Bool
}

public enum DiskUsage {
    /// Where a folder scan has got to, for the progress strip. Totals cover the finished items plus the one in progress.
    public struct ScanProgress: Sendable, Equatable {
        /// Top-level items found in the folder, and how many are fully measured.
        public var total: Int
        public var done: Int
        /// The item being measured now (nil between items or once finished).
        public var current: String?
        /// Files and folders examined so far, and their allocated size.
        public var files: Int
        public var bytes: UInt64
        public init(total: Int, done: Int, current: String?, files: Int, bytes: UInt64) {
            self.total = total; self.done = done; self.current = current; self.files = files; self.bytes = bytes
        }
        public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// The folder's top-level items to measure, in listing order: symlinks, missing items and the skipped system paths
    /// (see `skipped`) are left out, so the progress total matches what will be reported.
    public static func scanItems(of path: String) -> [(name: String, path: String, isDirectory: Bool)] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return items.compactMap { name in
            let p = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { return nil }
            if (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return nil }
            if isDir.boolValue && skipped.contains(p) { return nil }
            return (name, p, isDir.boolValue)
        }
    }

    /// /System/Volumes holds the Data volume that is already reachable through firmlinks (it would be counted twice),
    /// /Volumes holds other disks, /dev is devices, and /private/var/vm holds swap files whose size changes constantly.
    static let skipped: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm"]

    /// Measures each of `items` (from `scanItems`), reporting results as they finish (`entry`) and progress as it goes
    /// (`progress`: the item list up front, then every few hundred files and after each item). Unlike `children` it
    /// can be cancelled inside a large folder, within a few milliseconds. Blocking: call off the main thread.
    /// With `recorder`, every folder's rollup (size, subfolders, largest files) is saved as it goes, so the UI can show
    /// any subfolder of the scan without scanning again (see FolderTree); the saved scan is returned when it completes.
    /// A cancelled scan returns nil and nothing of it is kept.
    @discardableResult
    public static func scan(items: [(name: String, path: String, isDirectory: Bool)], recorder: FolderTreeRecorder? = nil,
                            progress: @Sendable (ScanProgress) -> Void,
                            entry: @Sendable (DirEntry) -> Void, cancelled: @Sendable () -> Bool) -> FolderTree? {
        var done: [DirEntry] = []
        var p = ScanProgress(total: items.count, done: 0, current: nil, files: 0, bytes: 0)
        progress(p)
        for item in items {
            if cancelled() { recorder?.discard(); return nil }
            p.current = item.name; progress(p)
            let filesBefore = p.files, bytesBefore = p.bytes
            var itemFiles = 0                  // the sizer's final count for this item (its last progress call)
            let builder = recorder.map { FolderTreeRecorder.Builder(recorder: $0, item: item.path) }
            let result = DirectorySizer.size(of: item.path, cancelled: cancelled, progress: { f, b in
                itemFiles = f
                var q = p; q.files = filesBefore + f; q.bytes = bytesBefore + b; progress(q)
            }, visit: { level, url, bytes, isDir in builder?.visit(level: level, url: url, bytes: bytes, isDirectory: isDir) })
            guard let result else { recorder?.discard(); return nil }   // cancelled
            if item.isDirectory { builder?.finish() }
            let size = result.bytes ?? 0       // unreadable items count as 0, as the footer explains
            // A plain file reports no progress (nothing to enumerate), so it counts as one.
            p.done += 1; p.bytes = bytesBefore + size; p.files = filesBefore + max(itemFiles, 1); p.current = nil
            let e = DirEntry(name: item.name, path: item.path, size: size, isDirectory: item.isDirectory)
            done.append(e); entry(e)
            progress(p)
        }
        return recorder?.finish(entries: done)
    }

    /// Immediate children of `path` with recursive sizes. Calls `progress` as each child completes.
    /// Runs synchronously on the caller's (background) thread; `cancelled` is polled between children so navigating away
    /// stops the walk early.
    public static func children(of path: String, progress: @Sendable (DirEntry) -> Void, cancelled: @Sendable () -> Bool) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else { return }
        for name in items {
            if cancelled() { return }
            let p = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            let url = URL(fileURLWithPath: p)
            // Symlinks are skipped so a link can't count a tree twice or loop.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            let size: UInt64
            if isDir.boolValue {
                // /System/Volumes holds the Data volume that is already reachable through firmlinks (it would be counted twice),
                // /Volumes holds other disks, /dev is devices, and /private/var/vm holds swap files whose size changes
                // constantly.
                if ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm"].contains(p) { continue }
                size = InstalledApps.size(of: p)
            } else {
                size = UInt64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
            progress(DirEntry(name: name, path: p, size: size, isDirectory: isDir.boolValue))
        }
    }
}
