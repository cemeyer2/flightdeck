import Foundation
import SQLite3

// On-disk store for folder-scan rollups (see FolderTree). Each finished folder is written as it closes and then
// forgotten, so a whole-disk scan costs a few MB of memory instead of gigabytes, and the last scan survives relaunches:
// drilling into any recorded folder is one indexed query. SQLite ships with macOS, so there's no dependency.
//
// The database holds file and folder names from the user's disk. It stays in Application Support, keeps only the latest
// scan of each folder (and a handful of scans overall), and the UI can forget it entirely.
//
// Thread-safety: reads use this object's connection under a lock; each scan writes through its own connection in one
// transaction (WAL mode), so the main thread can read earlier scans while a new one is written.

public final class FolderStore: @unchecked Sendable {
    public static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Flightdeck/folder-scans.sqlite")
    /// Scans kept overall (the newest; each folder's latest scan replaces its previous one anyway).
    public static let keepScans = 5

    private var db: OpaquePointer?
    private let lock = NSLock()
    public let url: URL

    public init?(url: URL = FolderStore.defaultURL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        // Schema v2 (children by folder id). A v1 file from a development build is simply recreated: it's only a cache.
        var version: Int32 = 0
        if let st = prepare("PRAGMA user_version") { if sqlite3_step(st) == SQLITE_ROW { version = sqlite3_column_int(st, 0) }; sqlite3_finalize(st) }
        if version < 2 { exec("DROP TABLE IF EXISTS children; DROP TABLE IF EXISTS folders; DROP TABLE IF EXISTS scans; PRAGMA user_version = 2") }
        exec("""
            PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS scans(id INTEGER PRIMARY KEY, root TEXT NOT NULL, date REAL NOT NULL,
                complete INTEGER NOT NULL DEFAULT 0, truncated INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS folders(id INTEGER PRIMARY KEY, scan INTEGER NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL,
                items INTEGER NOT NULL, other_count INTEGER NOT NULL, other_size INTEGER NOT NULL);
            CREATE UNIQUE INDEX IF NOT EXISTS folders_path ON folders(scan, path);
            -- Children point at their folder by id (not by repeating its path), which keeps the file small.
            CREATE TABLE IF NOT EXISTS children(folder INTEGER NOT NULL, name TEXT NOT NULL, size INTEGER NOT NULL, is_dir INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS children_folder ON children(folder);
            """)
        exec("PRAGMA wal_checkpoint(TRUNCATE)")   // tidy a -wal file left by an earlier run
    }
    deinit { sqlite3_close(db) }

    @discardableResult private func exec(_ sql: String) -> Bool { Self.exec(db, sql) }
    private func prepare(_ sql: String) -> OpaquePointer? { Self.prepare(db, sql) }
    @discardableResult static func exec(_ db: OpaquePointer?, _ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }
    static func prepare(_ db: OpaquePointer?, _ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK ? st : nil
    }

    // SQLITE_TRANSIENT: SQLite copies bound text (the Swift string's buffer doesn't outlive the call).
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private func bind(_ st: OpaquePointer?, _ i: Int32, _ s: String) { Self.bind(st, i, s) }
    static func bind(_ st: OpaquePointer?, _ i: Int32, _ s: String) { sqlite3_bind_text(st, i, s, -1, transient) }

    // MARK: Writing a scan

    /// Writes one scan inside a single transaction (fast, and nothing half-written is ever visible). `commit()` keeps
    /// it and drops older scans of the same folder; `discard()` (on cancel) throws it away.
    public final class Writer {
        /// Its own connection: with WAL, the main thread can keep reading earlier scans while this one is written.
        private var db: OpaquePointer?
        public let scanID: Int64
        private var folder: OpaquePointer?, child: OpaquePointer?
        private var closed = false

        init?(url: URL, root: String, date: Date) {
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
            sqlite3_busy_timeout(db, 5_000)
            FolderStore.exec(db, "BEGIN IMMEDIATE")
            guard let ins = FolderStore.prepare(db, "INSERT INTO scans(root, date) VALUES(?, ?)") else {
                FolderStore.exec(db, "ROLLBACK"); sqlite3_close(db); return nil
            }
            FolderStore.bind(ins, 1, root); sqlite3_bind_double(ins, 2, date.timeIntervalSince1970)
            sqlite3_step(ins); sqlite3_finalize(ins)
            scanID = sqlite3_last_insert_rowid(db)
            folder = FolderStore.prepare(db, "INSERT OR REPLACE INTO folders(scan, path, size, items, other_count, other_size) VALUES(?, ?, ?, ?, ?, ?)")
            child = FolderStore.prepare(db, "INSERT INTO children VALUES(?, ?, ?, ?)")
        }

        func folder(path: String, node: FolderNode) {
            guard let st = folder else { return }
            sqlite3_reset(st)
            sqlite3_bind_int64(st, 1, scanID); FolderStore.bind(st, 2, path)
            sqlite3_bind_int64(st, 3, Int64(node.size)); sqlite3_bind_int64(st, 4, Int64(node.items))
            sqlite3_bind_int64(st, 5, Int64(node.otherFiles.count)); sqlite3_bind_int64(st, 6, Int64(node.otherFiles.size))
            sqlite3_step(st)
            let id = sqlite3_last_insert_rowid(db)
            for (name, size) in node.folders { addChild(folder: id, name: name, size: size, dir: true) }
            for (name, size) in node.largestFiles { addChild(folder: id, name: name, size: size, dir: false) }
        }

        private func addChild(folder id: Int64, name: String, size: UInt64, dir: Bool) {
            guard let st = child else { return }
            sqlite3_reset(st)
            sqlite3_bind_int64(st, 1, id); FolderStore.bind(st, 2, name)
            sqlite3_bind_int64(st, 3, Int64(size)); sqlite3_bind_int(st, 4, dir ? 1 : 0)
            sqlite3_step(st)
        }

        /// Keeps the scan, replacing older scans of the same folder and trimming to the newest few overall.
        public func commit(truncated: Bool, root: String) {
            guard !closed else { return }; closed = true
            sqlite3_finalize(folder); sqlite3_finalize(child)
            FolderStore.exec(db, "UPDATE scans SET complete = 1, truncated = \(truncated ? 1 : 0) WHERE id = \(scanID)")
            if let st = FolderStore.prepare(db, "SELECT id FROM scans WHERE (root = ? AND id <> ?) OR id NOT IN (SELECT id FROM scans ORDER BY id DESC LIMIT \(FolderStore.keepScans))") {
                FolderStore.bind(st, 1, root); sqlite3_bind_int64(st, 2, scanID)
                var old: [Int64] = []
                while sqlite3_step(st) == SQLITE_ROW { old.append(sqlite3_column_int64(st, 0)) }
                sqlite3_finalize(st)
                for id in old {
                    FolderStore.exec(db, "DELETE FROM children WHERE folder IN (SELECT id FROM folders WHERE scan = \(id)); DELETE FROM folders WHERE scan = \(id); DELETE FROM scans WHERE id = \(id)")
                }
            }
            FolderStore.exec(db, "COMMIT")
            // Fold the write-ahead log back into the database and truncate it, so a big scan doesn't leave a large
            // -wal file sitting next to the database until the next write.
            FolderStore.exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
            sqlite3_close(db)
        }

        /// Throws the scan away (cancelled or superseded): nothing of it was ever visible.
        public func discard() {
            guard !closed else { return }; closed = true
            sqlite3_finalize(folder); sqlite3_finalize(child)
            FolderStore.exec(db, "ROLLBACK"); sqlite3_close(db)
        }
        deinit { discard() }
    }

    public func beginScan(root: String, date: Date = Date()) -> Writer? { Writer(url: url, root: root, date: date) }

    // MARK: Reading

    public struct ScanInfo: Sendable, Equatable { public var id: Int64; public var root: String; public var date: Date; public var truncated: Bool }

    /// The newest complete scan that recorded `path` (the folder itself or one inside the scanned folder).
    public func scan(covering path: String) -> ScanInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare("""
            SELECT s.id, s.root, s.date, s.truncated FROM scans s JOIN folders f ON f.scan = s.id AND f.path = ?
            WHERE s.complete = 1 ORDER BY s.id DESC LIMIT 1
            """) else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, 1, path)
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        return ScanInfo(id: sqlite3_column_int64(st, 0), root: String(cString: sqlite3_column_text(st, 1)),
                        date: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)), truncated: sqlite3_column_int(st, 3) != 0)
    }

    /// A recorded folder's contents (subfolders and its largest files, plus a "smaller files" row), largest first.
    public func entries(scan: Int64, path: String) -> [DirEntry]? {
        lock.lock(); defer { lock.unlock() }
        guard let f = prepare("SELECT id, other_count, other_size FROM folders WHERE scan = ? AND path = ?") else { return nil }
        sqlite3_bind_int64(f, 1, scan); bind(f, 2, path)
        guard sqlite3_step(f) == SQLITE_ROW else { sqlite3_finalize(f); return nil }
        let folderID = sqlite3_column_int64(f, 0)
        let otherCount = Int(sqlite3_column_int64(f, 1)), otherSize = UInt64(sqlite3_column_int64(f, 2))
        sqlite3_finalize(f)
        var out: [DirEntry] = []
        if let c = prepare("SELECT name, size, is_dir FROM children WHERE folder = ?") {
            sqlite3_bind_int64(c, 1, folderID)
            while sqlite3_step(c) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(c, 0))
                out.append(DirEntry(name: name, path: (path as NSString).appendingPathComponent(name),
                                    size: UInt64(sqlite3_column_int64(c, 1)), isDirectory: sqlite3_column_int(c, 2) != 0))
            }
            sqlite3_finalize(c)
        }
        if otherCount > 0 { out.append(DirEntry(name: "\(otherCount.formatted()) smaller files", path: path + "/\u{0}other", size: otherSize, isDirectory: false)) }
        return out.sorted { $0.size > $1.size }
    }

    /// The most recent complete scan, if any (shown when the Folder Scanner opens).
    public func latestScan() -> ScanInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare("SELECT id, root, date, truncated FROM scans WHERE complete = 1 ORDER BY id DESC LIMIT 1") else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        return ScanInfo(id: sqlite3_column_int64(st, 0), root: String(cString: sqlite3_column_text(st, 1)),
                        date: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)), truncated: sqlite3_column_int(st, 3) != 0)
    }

    /// Deletes every saved scan (Disk Space › Forget Saved Scans).
    public func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM children; DELETE FROM folders; DELETE FROM scans; VACUUM")
    }
}
