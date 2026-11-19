import Foundation
import Darwin

// The I/O half of BootHistory: reads wtmp, logd's shutdown log, the power log and the panic reports, none of which
// needs root. The unified-log query for shutdown causes is separate (ShutdownCauseLog.query) because it is the slow
// part and runs only for boots FlightDeck hasn't resolved yet.

public enum BootSourcesReader {
    /// One wtmp record of the kinds used here.
    public struct WtmpRecord: Sendable, Hashable {
        public enum Kind: Sendable { case boot, shutdown, consoleLogin }
        public var kind: Kind
        public var time: Date
        public var user: String
    }

    /// Boot, shutdown and console-login records from wtmp (/var/log/utmpx, readable by everyone), the source `last`
    /// uses. It reaches back to when the file was last reset, typically a macOS install or major update.
    public static func wtmp() -> [WtmpRecord] {
        var out: [WtmpRecord] = []
        setutxent_wtmp(0)   // 0 = read newest first
        defer { endutxent_wtmp() }
        while let p = getutxent_wtmp() {
            let u = p.pointee
            let t = Date(timeIntervalSince1970: Double(u.ut_tv.tv_sec) + Double(u.ut_tv.tv_usec) / 1e6)
            func str<T>(_ v: T) -> String { withUnsafeBytes(of: v) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
            switch Int32(u.ut_type) {
            case BOOT_TIME: out.append(WtmpRecord(kind: .boot, time: t, user: ""))
            case SHUTDOWN_TIME: out.append(WtmpRecord(kind: .shutdown, time: t, user: ""))
            case USER_PROCESS where str(u.ut_line) == "console": out.append(WtmpRecord(kind: .consoleLogin, time: t, user: str(u.ut_user)))
            default: break
            }
        }
        return out
    }

    /// Orderly shutdowns from logd's shutdown log. logd appends "SIGTERM: [<unix time>] All buffers flushed" when
    /// launchd stops it during a proper shutdown or restart; a crash, power loss or forced power-off never gets that far.
    /// The file is world-readable. Rotated copies (shutdown.1.log …) are read too.
    public static func logdFlushes(dir: String = "/private/var/db/diagnostics") -> [Date] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("shutdown") && $0.hasSuffix(".log") }
        return files.flatMap { f -> [Date] in
            guard let text = try? String(contentsOfFile: dir + "/" + f, encoding: .utf8) else { return [] }
            return parseFlushes(text)
        }.sorted()
    }

    public static func parseFlushes(_ text: String) -> [Date] {
        text.matches(of: #/SIGTERM: \[(\d{9,11})\] All buffers flushed/#).compactMap { m in Double(m.1).map { Date(timeIntervalSince1970: $0) } }
    }

    /// Shutdown, restart, start and hibernation wakes from `pmset -g log` text. The power log keeps about a week. The
    /// event type is the padded field after the timestamp, as in SleepLog; only types starting with Shutdown, Restart or
    /// Start are taken, plus Wake lines that mention hibernation or standby (a wake that restored memory from disk).
    public static func parsePowerLog(_ text: String) -> [PowerLogEvent] {
        var out: [PowerLogEvent] = []
        for line in text.split(separator: "\n") where line.utf8.count > 26 {
            let type = line.dropFirst(26).prefix(20).trimmingCharacters(in: .whitespaces)
            let kind: PowerLogEvent.Kind
            let msg = line.firstIndex(of: "\t").map { String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
            if type.hasPrefix("Shutdown") { kind = .shutdown }
            else if type.hasPrefix("Restart") { kind = .restart }
            else if type == "Start" || type.hasPrefix("Start ") { kind = .start }
            else if type == "Wake", msg.range(of: "hibernat", options: .caseInsensitive) != nil || msg.range(of: "standby", options: .caseInsensitive) != nil { kind = .hibernateWake }
            else { continue }
            guard let t = SleepLog.stamp.date(from: String(line.prefix(25))) else { continue }
            out.append(PowerLogEvent(time: t, kind: kind, message: String(msg.prefix(200))))
        }
        return out
    }

    /// Reads every source except the unified log. `causes` comes from the caller (stored history plus any new queries).
    /// Blocking (pmset can take a couple of seconds); call off the main thread.
    public static func read(panicsSince: Date, causes: [ShutdownCauseEntry]) -> BootSources {
        var s = BootSources()
        let w = wtmp()
        s.boots = w.filter { $0.kind == .boot }.map(\.time)
        if let kb = Sysctl.timeval("kern.boottime") { s.boots.append(kb) }
        s.shutdownRecords = w.filter { $0.kind == .shutdown }.map(\.time)
        s.logins = w.filter { $0.kind == .consoleLogin && $0.user != "root" }.map(\.time)
        s.logdFlushes = logdFlushes()
        s.panics = PanicReports.scan(since: panicsSince)
        if let log = Shell.run("/usr/bin/pmset", ["-g", "log"], timeout: 20) {
            s.power = parsePowerLog(log)
            // The first timestamped line ("PM ASL data store: …" headers come first).
            s.powerLogSince = log.split(separator: "\n").prefix(20).lazy.compactMap { SleepLog.stamp.date(from: String($0.prefix(25))) }.first
        }
        s.causes = causes
        return s
    }

    /// The current user's first console login after `boot` (wtmp), or nil.
    public static func login(after boot: Date, user: String = NSUserName(), records: [WtmpRecord]) -> Date? {
        records.filter { $0.kind == .consoleLogin && $0.user == user && $0.time >= boot }.map(\.time).min()
    }
}
