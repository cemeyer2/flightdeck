import Foundation

// Feeds the Flight Log's "macOS reports" list and Engine's report findings. These files are written by ReportCrash,
// spindump and the resource-limit monitors; FlightDeck only reads them, so it sees incidents even from times it
// wasn't running. Reports in /Library that the user can't read are silently skipped.
/// macOS's own incident reports (crashes, hangs, memory kills, CPU and disk-write limit violations) from
/// ~/Library/Logs/DiagnosticReports and /Library/Logs/DiagnosticReports. Only headers are read.
public struct DiagnosticReport: Sendable, Hashable, Identifiable {
    /// Report category; rawValue is the UI label. userFault is a non-fatal "simulated crash" (ExcUserFault) that an app
    /// or the system recorded without the process dying. cpuLimit/diskWrites/wakeups are the resource-limit violations
    /// macOS logs when a process exceeds its CPU, disk-write or wake-up budget.
    public enum Kind: String, Sendable, CaseIterable {
        case crash = "Crash", panic = "Kernel panic", userFault = "Fault (not fatal)", hang = "Hang", jetsam = "Killed for memory",
             cpuLimit = "CPU limit", diskWrites = "Disk-write limit", wakeups = "Wake-up limit", other = "Report"
        public var icon: String {
            switch self {
            case .crash: "xmark.octagon"; case .panic: "exclamationmark.octagon.fill"; case .userFault: "exclamationmark.bubble"; case .hang: "hourglass"
            case .jetsam: "memorychip"; case .cpuLimit: "cpu"; case .diskWrites: "internaldrive"; case .wakeups: "alarm"; case .other: "doc.text"
            }
        }
        /// Only events that hurt the user directly (crash, hang, memory kill) rise above informational.
        public var severity: Finding.Severity {
            switch self { case .panic: .warning; case .crash, .hang, .jetsam: .caution; default: .info }
        }
    }
    public var id: String { path }
    public var path: String
    public var kind: Kind
    public var process: String
    public var time: Date
    /// Short detail when the header has one (exception type / signal, writes, CPU used, hang duration).
    public var summary: String?
}

public enum DiagnosticReports {
    /// The per-user and system-wide report folders. Subfolders (e.g. "Retired") are not scanned.
    public static let directories = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports").path,
        "/Library/Logs/DiagnosticReports",
    ]

    /// Reports modified after `since`, newest first.
    /// Lists candidate files by extension and modification date, then parses at most `limit` of the newest so a folder
    /// full of old reports can't make a scan slow. Blocking file I/O; run off the main thread.
    public static func scan(since: Date, directories: [String] = directories, limit: Int = 300) -> [DiagnosticReport] {
        var files: [(URL, Date)] = []
        for d in directories {
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: d), includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? []
            for u in urls where ["ips", "diag", "hang", "crash", "spin"].contains(u.pathExtension) {
                guard let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m >= since else { continue }
                files.append((u, m))
            }
        }
        // newest files first for the limit, then by when the event happened (a report can be written hours later)
        return files.sorted { $0.1 > $1.1 }.prefix(limit).compactMap { parse($0.0, modified: $0.1) }.sorted { $0.time > $1.time }
    }

    /// .ips JSON header timestamps use centiseconds ("2026-11-16 00:10:00.00 -0600"); the plain-text "Date/Time" field
    /// uses milliseconds, hence two formatters.
    static let headerDate: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"; return f }()
    static let textDate: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"; return f }()

    /// The first `bytes` bytes of a file. Reports can be megabytes of stack data; the header (and, for .ips, the start
    /// of the body with the exception info) fits in 8 KB.
    static func head(_ u: URL, bytes: Int = 8192) -> String? {
        guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
        defer { try? h.close() }
        return (try? h.read(upToCount: bytes)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Classifies one report. Unparseable dates fall back to the file's modification time; nil only if the file can't
    /// be read.
    public static func parse(_ u: URL, modified: Date) -> DiagnosticReport? {
        guard let text = head(u) else { return nil }
        if u.pathExtension == "ips", let first = text.split(separator: "\n", maxSplits: 1).first,
           let hdr = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any] {
            // .ips files are a one-line JSON header followed by a JSON (or text) body. The header's bug_type identifies the
            // report: 309 (and legacy 109, 210) crash, 298 JetsamEvent, 288/228 hang/spin, 202 CPU resource, 145 disk writes.
            // A simulated crash (is_simulated, or an ExcUserFault file) is a non-fatal fault rather than a crash.
            let bug = hdr["bug_type"] as? String ?? ""
            let name = (hdr["app_name"] as? String) ?? (hdr["name"] as? String) ?? (u.lastPathComponent.split(separator: "-").first.map(String.init) ?? "?")
            let time = (hdr["timestamp"] as? String).flatMap { headerDate.date(from: $0) } ?? modified
            let simulated = (hdr["is_simulated"] as? Int) == 1 || u.lastPathComponent.hasPrefix("ExcUserFault")
            let kind: DiagnosticReport.Kind
            switch bug {
            case "309", "109": kind = simulated ? .userFault : .crash
            case "210": kind = .panic   // kernel panic report (the whole Mac restarted)
            case "298": kind = .jetsam
            case "288", "228": kind = .hang
            case "202": kind = .cpuLimit
            case "145": kind = .diskWrites
            default: kind = .other
            }
            var summary: String?
            if kind == .crash || kind == .userFault {
                // exception type lives in the body; the start of the body is enough
                if let r = text.range(of: #""type" : "(EXC_[A-Z_]+)""#, options: .regularExpression) {
                    summary = String(text[r]).components(separatedBy: "\"").dropLast().last
                }
                if let r = text.range(of: #""signal" : "(SIG[A-Z]+)""#, options: .regularExpression),
                   let sig = String(text[r]).components(separatedBy: "\"").dropLast().last {
                    summary = [summary, sig].compactMap { $0 }.joined(separator: " / ")
                }
            }
            // A Jetsam report describes a system-wide memory event listing many processes, so it is attributed to "System".
            if kind == .jetsam {
                return DiagnosticReport(path: u.path, kind: .jetsam, process: "System", time: time, summary: "macOS killed processes to free memory")
            }
            return DiagnosticReport(path: u.path, kind: kind, process: name, time: time, summary: summary)
        }
        // Plain-text reports (.diag/.hang/.spin): "Key:   value" header lines
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n").prefix(60) {
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = line[..<c].trimmingCharacters(in: .whitespaces)
            if fields[k] == nil { fields[k] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces) }
        }
        let event = (fields["Event"] ?? "").lowercased()
        // The "Event" header field distinguishes the resource-limit reports ("disk writes", "cpu usage", "wakeups").
        let kind: DiagnosticReport.Kind = u.pathExtension == "hang" || u.pathExtension == "spin" || event.contains("hang") ? .hang
            : event.contains("disk writes") ? .diskWrites : event.contains("cpu") ? .cpuLimit : event.contains("wakeups") ? .wakeups
            : u.pathExtension == "crash" ? .crash : .other
        let time = fields["Date/Time"].flatMap { textDate.date(from: $0) } ?? modified
        let name = fields["Command"].flatMap { $0.isEmpty ? nil : $0 } ?? (u.lastPathComponent.split(separator: "_").first.map(String.init) ?? "?")
        let summary = fields["Writes"] ?? fields["CPU"] ?? fields["Wakeups"] ?? fields["Duration"].map { "lasted \($0)" }
        return DiagnosticReport(path: u.path, kind: kind, process: name, time: time, summary: summary)
    }

    /// Repeated crashes/hangs of the same app in the last 24 h become a finding.
    /// Grouped by kind and process name; only 2+ occurrences count, since a single crash is already visible in the list.
    /// `since` is the first occurrence in the window so the finding reads as ongoing from then.
    public static func findings(_ reports: [DiagnosticReport], now: Date = Date()) -> [Finding] {
        let recent = reports.filter { now.timeIntervalSince($0.time) <= 86_400 && [.crash, .hang].contains($0.kind) }
        let byApp = Dictionary(grouping: recent) { "\($0.kind.rawValue)|\($0.process)" }
        return byApp.compactMap { _, rs in
            guard rs.count >= 2, let r = rs.max(by: { $0.time < $1.time }) else { return nil }
            let verb = r.kind == .crash ? "crashed" : "hung"
            return Finding(id: "report:\(r.kind.rawValue):\(r.process)", severity: .caution, icon: r.kind.icon,
                           title: "\(r.process) \(verb) \(rs.count) times in the last 24 hours",
                           detail: (r.summary.map { "Last: \($0). " } ?? "") + "macOS saved a report each time (Flight Log › macOS reports).",
                           since: rs.map(\.time).min()!, destination: "Flight Log")
        }.sorted { $0.title < $1.title }
    }
}
