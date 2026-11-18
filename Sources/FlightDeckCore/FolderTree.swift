import Foundation

// Per-folder rollups recorded during a folder scan, so drilling into a subfolder (or going back up) shows its contents
// instantly instead of scanning it again, even after a relaunch. The scan already visits every file; this records, for
// each folder, its total size, its subfolders with their totals, and its largest files.
//
// Built with a stack of open folders as the depth-first enumeration descends and climbs (constant work per file, no
// path lookups). Each folder is written to the FolderStore (SQLite) when it closes and then forgotten, so memory stays
// flat however big the scan is: only the open path from the scanned folder to the current one is held. Limits keep the
// database reasonable: folders deeper than `maxDepth` still count toward their ancestors but aren't recorded
// themselves, at most `maxNodes` folders are recorded, and only each folder's `filesPerFolder` largest files are kept
// by name (the rest are summed). Drilling into a folder that wasn't recorded falls back to a fresh scan.

/// One folder's rollup while it's open.
public struct FolderNode: Sendable {
    public var size: UInt64
    /// Files and folders anywhere below it.
    public var items: Int
    /// Direct subfolders and their totals.
    public var folders: [(name: String, size: UInt64)]
    /// Its largest direct files, largest first; the others are summed in `otherFiles`.
    public var largestFiles: [(name: String, size: UInt64)]
    public var otherFiles: (count: Int, size: UInt64)
    static let empty = FolderNode(size: 0, items: 0, folders: [], largestFiles: [], otherFiles: (0, 0))
}

/// A finished, saved scan: answers "what's in this folder?" for any folder it recorded.
public final class FolderTree: @unchecked Sendable {
    public let store: FolderStore
    public let info: FolderStore.ScanInfo
    public var root: String { info.root }
    public var date: Date { info.date }
    /// True when `maxNodes` was reached, so some folders weren't recorded.
    public var truncated: Bool { info.truncated }

    public static let maxDepth = 12
    public static let maxNodes = 2_000_000
    public static let filesPerFolder = 50

    public init(store: FolderStore, info: FolderStore.ScanInfo) { self.store = store; self.info = info }

    /// The folder's contents (subfolders and largest files, plus a "N smaller files" row), or nil if it wasn't recorded.
    public func entries(of path: String) -> [DirEntry]? { store.entries(scan: info.id, path: path) }

    /// Whether `path` lies inside this scan (so it may be answered from it).
    public func covers(_ path: String) -> Bool { path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }

    /// Keeps a file among a folder's largest, or adds it to the "smaller files" sum. The list stays sorted, largest
    /// first, by inserting in place (binary search) rather than re-sorting.
    static func keep(_ node: inout FolderNode, _ name: String, _ size: UInt64) {
        if node.largestFiles.count == filesPerFolder {
            guard let smallest = node.largestFiles.last, size > smallest.size else {
                node.otherFiles.count += 1; node.otherFiles.size += size; return
            }
            node.otherFiles.count += 1; node.otherFiles.size += smallest.size
            node.largestFiles.removeLast()
        }
        var lo = 0, hi = node.largestFiles.count
        while lo < hi { let mid = (lo + hi) / 2; if node.largestFiles[mid].size >= size { lo = mid + 1 } else { hi = mid } }
        node.largestFiles.insert((name, size), at: lo)
    }
}

/// Records one scan into the store as it runs. Feed each top-level folder's walk through a `Builder`, then `finish`.
public final class FolderTreeRecorder: @unchecked Sendable {
    let writer: FolderStore.Writer
    let store: FolderStore
    public let root: String
    let date: Date
    var recorded = 0
    var truncated = false

    public init?(store: FolderStore, root: String, date: Date = Date()) {
        guard let w = store.beginScan(root: root, date: date) else { return nil }
        writer = w; self.store = store; self.root = root; self.date = date
    }

    func write(path: String, node: FolderNode) {
        guard recorded < FolderTree.maxNodes else { truncated = true; return }
        var n = node; n.folders.sort { $0.size > $1.size }
        writer.folder(path: path, node: n); recorded += 1
    }

    /// Records the scanned folder itself from its finished items and saves the scan; returns its handle.
    func finish(entries: [DirEntry]) -> FolderTree? {
        var node = FolderNode.empty
        for e in entries {
            node.size += e.size; node.items += 1
            if e.isDirectory { node.folders.append((e.name, e.size)) } else { FolderTree.keep(&node, e.name, e.size) }
        }
        write(path: root, node: node)
        writer.commit(truncated: truncated, root: root)
        return FolderTree(store: store, info: FolderStore.ScanInfo(id: writer.scanID, root: root, date: date, truncated: truncated))
    }

    /// Drops the partial scan (cancelled or superseded).
    func discard() { writer.discard() }

    /// Accumulates one top-level item's subtree from the sizer's `visit` calls; `finish()` closes it.
    final class Builder {
        let recorder: FolderTreeRecorder
        /// Open folders from the item down to the current one. Depth is relative to the scanned folder (item = 1).
        private var stack: [(path: String, depth: Int, node: FolderNode)] = []

        init(recorder: FolderTreeRecorder, item path: String) {
            self.recorder = recorder
            stack = [(path, 1, .empty)]
        }

        /// `level` is the enumerator's depth below the item (1 = direct child).
        func visit(level: Int, url: URL, bytes: UInt64, isDirectory: Bool) {
            while stack.count > level { pop() }
            let i = stack.count - 1
            stack[i].node.items += 1
            stack[i].node.size += bytes   // a file, or a folder entry's own allocation
            if isDirectory {
                // Child paths are built from the parent's, not taken from `url`: the enumerator resolves symlinked
                // ancestors (/var → /private/var), and keys must match the spelling the scan (and the UI) started from.
                let path = (stack[i].path as NSString).appendingPathComponent(url.lastPathComponent)
                stack.append((path, stack[i].depth + 1, .empty))
            } else {
                FolderTree.keep(&stack[i].node, url.lastPathComponent, bytes)
            }
        }

        /// Closes the innermost open folder: records it (within the limits) and adds it to its parent.
        private func pop() {
            let done = stack.removeLast()
            if done.depth <= FolderTree.maxDepth { recorder.write(path: done.path, node: done.node) }
            guard !stack.isEmpty else { return }
            let i = stack.count - 1
            stack[i].node.size += done.node.size
            stack[i].node.items += done.node.items
            stack[i].node.folders.append(((done.path as NSString).lastPathComponent, done.node.size))
        }

        /// Closes every open folder, including the item itself.
        func finish() { while !stack.isEmpty { pop() } }
    }
}
