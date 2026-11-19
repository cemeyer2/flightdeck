import Foundation
// Marks: named timestamps a coding agent (through the MCP `mark` tool) or a person sets around a piece of work, so
// FlightDeck can later measure what the Mac did between two of them (`measure`, WindowMeasure.swift). They are the
// only thing any MCP tool writes, and they live in FlightDeck's own folder, never anywhere else.
//
// Two processes write the same file: the app (when its MCP server answers) and `FlightDeck --mcp` running standalone.
// Every operation therefore re-reads the file under an advisory lock (flock) and writes it back atomically, so neither
// loses the other's marks and the Flight Log timeline (which only reads) never sees half a file.

/// One named moment.
public struct Mark: Codable, Sendable, Hashable, Identifiable {
    /// Short and unique, e.g. "m-lx3k9q2a": "m-" and the time in milliseconds in base 36 (plus a suffix if two marks
    /// share a millisecond). Sortable by time within the same length, and easy for a model to copy back.
    public var id: String
    public var label: String
    public var time: Date
    /// Who set it ("mcp" for the tool); free text, shown in the timeline's tooltip.
    public var source: String?
    public init(id: String, label: String, time: Date, source: String? = nil) {
        self.id = id; self.label = label; self.time = time; self.source = source
    }
}

/// The marks file. Cheap to create: it holds only the file's URL; nothing is cached between calls.
public final class MarkStore: @unchecked Sendable {
    /// Marks older than this are dropped on every write (and ignored on read): the black box keeps 24 h, so a mark past
    /// 48 h can't anchor a measurement any more; the extra day keeps yesterday's marks visible for context.
    public static let retention: TimeInterval = 48 * 3600
    /// Hard cap on the number kept (newest win), so a looping agent can't grow the file without bound.
    public static let maxMarks = 1000
    /// Labels are cut to this many characters: they are names, not notes.
    public static let maxLabel = 120

    public let url: URL
    public init(url: URL = MarkStore.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flightdeck/marks.json")   // see BlackBox.defaultDirectory for the folder's spelling
    }

    public enum StoreError: Error, CustomStringConvertible {
        case emptyLabel, io(String)
        public var description: String {
            switch self { case .emptyLabel: "label must not be empty"; case .io(let s): "couldn't save the mark: \(s)" }
        }
    }

    /// Records a mark at `time` and returns it. Expired marks are pruned in the same write.
    @discardableResult
    public func add(label raw: String, at time: Date = Date(), source: String? = "mcp") throws -> Mark {
        let label = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLabel))
        guard !label.isEmpty else { throw StoreError.emptyLabel }
        return try locked { () throws -> Mark in
            var marks = Self.live(read(), now: time)
            let ids = Set(marks.map(\.id))
            let base = "m-" + String(Int64((time.timeIntervalSince1970 * 1000).rounded()), radix: 36)
            var id = base, n = 1
            while ids.contains(id) { n += 1; id = "\(base)-\(n)" }
            let m = Mark(id: id, label: label, time: time, source: source)
            marks.append(m)
            marks.sort { $0.time < $1.time }
            if marks.count > Self.maxMarks { marks.removeFirst(marks.count - Self.maxMarks) }
            try write(marks)
            return m
        }
    }

    /// Unexpired marks, oldest first. A missing or unreadable file reads as no marks.
    public func all(now: Date = Date()) -> [Mark] { Self.live(read(), now: now) }

    /// Resolves a reference to a mark: an exact id first, else the most recent mark with that label (case-insensitive),
    /// optionally only among marks at or before `notAfter` (so "start" pairs with the latest start before an end).
    public func find(_ ref: String, notAfter: Date? = nil, now: Date = Date()) -> Mark? {
        let marks = all(now: now)
        if let m = marks.first(where: { $0.id == ref }) { return m }
        let key = ref.trimmingCharacters(in: .whitespaces).lowercased()
        return marks.last { m in m.label.lowercased() == key && (notAfter.map { m.time <= $0 } ?? true) }
    }

    /// Drops expired marks and keeps only the newest `maxMarks`.
    static func live(_ marks: [Mark], now: Date) -> [Mark] {
        Array(marks.filter { now.timeIntervalSince($0.time) <= retention }.sorted { $0.time < $1.time }.suffix(maxMarks))
    }

    // MARK: File access

    private func read() -> [Mark] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([Mark].self, from: data)) ?? []
    }

    private func write(_ marks: [Mark]) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.sortedKeys]
        do { try enc.encode(marks).write(to: url, options: .atomic) } catch { throw StoreError.io(error.localizedDescription) }
    }

    /// Runs `body` holding an exclusive flock on a sibling lock file. The marks file itself can't carry the lock,
    /// since atomic writes replace it with a new inode. If the lock can't be taken the body still runs: losing the
    /// race between two simultaneous writers is better than refusing to record a mark.
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return try body()
    }
}
