import Foundation

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

public struct DirEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var size: UInt64
    public var isDirectory: Bool
}

public enum DiskUsage {
    /// Immediate children of `path` with recursive sizes. Calls `progress` as each child completes.
    public static func children(of path: String, progress: @Sendable (DirEntry) -> Void, cancelled: @Sendable () -> Bool) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else { return }
        for name in items {
            if cancelled() { return }
            let p = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            let url = URL(fileURLWithPath: p)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            let size: UInt64
            if isDir.boolValue {
                if ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm"].contains(p) { continue }
                size = InstalledApps.size(of: p)
            } else {
                size = UInt64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
            progress(DirEntry(name: name, path: p, size: size, isDirectory: isDir.boolValue))
        }
    }
}
