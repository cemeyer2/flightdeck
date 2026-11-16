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
