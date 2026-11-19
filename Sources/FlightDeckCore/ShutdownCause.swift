import Foundation

// Shutdown cause codes for the Restarts & Crashes page. At every boot the kernel logs the previous shutdown's cause as
// a number ("Previous shutdown cause: 5"), taken from the SMC (Intel) or the power controller (Apple silicon). Apple
// has never documented these numbers: the meanings below are the ones repeatedly reported by Apple support staff,
// repair technicians and developers over many years. Each entry says how well established it is, and any code not in
// the table is shown as "undocumented" with its number, never guessed.

/// What one shutdown cause code means and whether it should worry the user.
public struct ShutdownCause: Sendable, Hashable, Codable {
    /// How much to read into the code. `.established` is not "documented by Apple" (none are) but widely and
    /// consistently reported; `.reported` has fewer or partly conflicting reports; `.undocumented` is unknown.
    public enum Certainty: String, Sendable, Codable { case established = "widely reported", reported = "reported, not confirmed", undocumented }
    /// normal = an orderly shutdown or restart; notable = forced or power-related but explainable; concern = hardware
    /// protection or a system failure worth acting on if it repeats.
    public enum Concern: String, Sendable, Codable { case normal, notable, concern, unknown }

    public var code: Int
    public var title: String
    public var meaning: String
    public var advice: String?
    public var concern: Concern
    public var certainty: Certainty
    /// true for the codes that mean the Mac did not shut down in an orderly way.
    public var unexpected: Bool { concern != .normal }

    /// The entry for `code`; unknown codes get an honest "undocumented" entry instead of a guess.
    public static func of(_ code: Int) -> ShutdownCause {
        if let k = table[code] {
            return ShutdownCause(code: code, title: k.0, meaning: k.1, advice: k.2, concern: k.3, certainty: k.4)
        }
        return ShutdownCause(code: code, title: "Undocumented cause \(code)",
                             meaning: "macOS recorded shutdown cause \(code). Apple doesn't document these codes and this one has no reliable public meaning.",
                             advice: "If it repeats, note the code and the time and mention them to Apple Support.",
                             concern: .unknown, certainty: .undocumented)
    }

    private typealias Entry = (String, String, String?, Concern, Certainty)
    // Sorted by code. Negative codes are hardware protection (SMC/PMU); small positive codes are software and power.
    private static let table: [Int: Entry] = [
        5: ("Normal shutdown", "Shut down or restarted normally (from the Apple menu, an update, or software).", nil, .normal, .established),
        3: ("Forced shutdown", "Hard shutdown: the power button was held down, or the Mac was forced off.",
            "Fine once in a while. If you had to force it because the Mac froze, see the freezes and panics on this page.", .notable, .established),
        0: ("Power lost", "Power was cut: the plug was pulled, the power failed, or the battery was removed or fully empty.",
            "On a desktop, check the power cable and outlet; a UPS protects against outages.", .notable, .established),
        1: ("Power lost or forced off", "Usually reported after a power interruption or a forced power-off.", nil, .notable, .reported),
        2: ("Battery empty", "Reported when the battery ran out completely.", "Charge sooner, or check battery health in Checkup.", .notable, .reported),
        6: ("Restart after a reset", "Reported after the system controller reset the Mac.", nil, .notable, .reported),
        7: ("CPU thread error", "Reported for a processor-level fault.", "If it repeats, run Apple Diagnostics (hold D at startup on Intel; the power button on Apple silicon).", .concern, .reported),
        -2: ("Power supply problem", "Reported for a power supply or adapter fault.", "Try another power adapter and outlet.", .concern, .reported),
        -3: ("Overheating", "Several temperature sensors exceeded their limit, so the Mac turned itself off to protect itself.",
             "Keep the vents clear, avoid soft surfaces, and check the Thermals page. Repeated thermal shutdowns need service.", .concern, .established),
        -20: ("Shut down by the security chip", "Reported on Macs with a T2 chip when the chip forced a shutdown.", "If it repeats, update macOS and contact Apple Support.", .concern, .reported),
        -60: ("Disk problem", "Bad master directory block: the startup disk had a problem during shutdown.",
              "Run First Aid in Disk Utility and make sure your backups are current.", .concern, .established),
        -61: ("Watchdog: unresponsive system (shut down)", "The watchdog found the system unresponsive and shut it down.",
              "Look for a kernel panic or a hang just before, and for third-party drivers or system extensions.", .concern, .established),
        -62: ("Watchdog: unresponsive system (restarted)", "The watchdog found the system unresponsive and restarted it.",
              "Look for a kernel panic or a hang just before, and for third-party drivers or system extensions.", .concern, .established),
        -64: ("Kernel failure", "Reported after a kernel panic or a serious kernel error.", "See the panic reports on this page for the culprit.", .concern, .reported),
        -65: ("Operating system problem", "Reported when the shutdown came from an OS-level failure.", "Update macOS; if it repeats, reinstall it.", .concern, .reported),
        -71: ("Overheating (memory)", "Overtemperature shutdown: a memory or other temperature sensor exceeded its limit.",
              "Keep the vents clear and check the Thermals page. Repeated cases need service.", .concern, .established),
        -74: ("Battery too hot", "The battery temperature exceeded its limit.", "Let the Mac cool, keep it out of the sun and off soft surfaces; check battery health.", .concern, .established),
        -75: ("Power adapter problem", "Communication with the power adapter failed.", "Try another adapter or cable.", .concern, .reported),
        -78: ("Power adapter current wrong", "Incorrect current from the power adapter.", "Try another adapter or cable.", .concern, .reported),
        -79: ("Battery current wrong", "Incorrect current from the battery.", "Check battery health in Checkup; the battery may need service.", .concern, .reported),
        -86: ("Overheating (proximity sensor)", "A proximity temperature sensor exceeded its limit.", "Keep the vents clear; repeated cases need service.", .concern, .reported),
        -95: ("Overheating (CPU)", "The CPU temperature exceeded its limit.", "Keep the vents clear and check the Thermals page; repeated cases need service.", .concern, .reported),
        -100: ("Overheating (power supply)", "The power supply temperature exceeded its limit.", "Check ventilation; repeated cases need service.", .concern, .reported),
        -102: ("Overvoltage", "An overvoltage protection tripped.", "Try another adapter and outlet; repeated cases need service.", .concern, .reported),
        -103: ("Battery voltage too low", "A battery cell fell below its minimum voltage.", "Check battery health in Checkup.", .concern, .reported),
        -112: ("Possibly memory", "Reported in connection with memory faults; not well established.", "If it repeats, run Apple Diagnostics.", .concern, .reported),
        -127: ("Forced off by the power controller", "The power management controller forced a shutdown.", nil, .concern, .reported),
        -128: ("Power button or forced shutdown", "Often reported after the power button was held or a forced shutdown; its exact meaning isn't established.",
               "If you didn't force it off, note the time and watch for a pattern.", .notable, .reported),
    ]
}

/// One "Previous shutdown cause" line from the kernel's boot messages.
public struct ShutdownCauseEntry: Sendable, Hashable, Codable {
    /// When the kernel logged it (during the boot that followed the shutdown).
    public var logged: Date
    public var code: Int
    public init(logged: Date, code: Int) { self.logged = logged; self.code = code }
}

public enum ShutdownCauseLog {
    /// Kept tight so `log show` reads only the kernel's lines: the predicate on process is evaluated before the message.
    /// The wording has been "Previous shutdown cause: N" since at least macOS 10.12; CONTAINS[c] tolerates the
    /// capitalisation variants seen on some versions and an "AppleSMC:" style prefix.
    public static let predicate = #"process == "kernel" AND eventMessage CONTAINS[c] "shutdown cause""#

    /// Extracts the code from a message such as "Previous shutdown cause: -128" or "AppleSMC: Previous Shutdown Cause: 3".
    public static func code(in message: String) -> Int? {
        guard let m = message.firstMatch(of: #/(?i)previous\s+shutdown\s+cause\s*[:=]?\s*(-?\d+)/#) else { return nil }
        return Int(m.1)
    }

    /// Parses `log show --style ndjson` output. Lines that aren't log events or don't carry a code are skipped.
    public static func parse(ndjson: String) -> [ShutdownCauseEntry] {
        // LogParser keeps only errors and faults; this message is logged at the default level, so it's decoded here.
        ndjson.split(separator: "\n").compactMap { line in
            guard line.first == "{", let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let msg = o["eventMessage"] as? String, let c = code(in: msg),
                  let t = (o["timestamp"] as? String).flatMap(LogParser.parseTimestamp) else { return nil }
            return ShutdownCauseEntry(logged: t, code: c)
        }
    }

    /// Asks the unified log for the cause logged in the first minutes after `boot`. The window is a few minutes wide, so
    /// the query reads one or two log files and takes about a second, rather than the minutes a 30-day search takes.
    /// Returns nil when the log no longer covers that boot (it keeps only days, rotated by size) or `log` failed.
    /// Blocking; call off the main thread.
    public static func query(boot: Date, timeout: TimeInterval = 20) -> ShutdownCauseEntry? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        let args = ["show", "--style", "ndjson", "--predicate", predicate,
                    "--start", f.string(from: boot.addingTimeInterval(-60)), "--end", f.string(from: boot.addingTimeInterval(600))]
        guard let out = Shell.run("/usr/bin/log", args, timeout: timeout) else { return nil }
        return parse(ndjson: out).min { $0.logged < $1.logged }
    }

    /// The oldest entry the unified log still holds, as a rough measure of how far back causes can be found. Cheap:
    /// `log show` prints entries oldest first, so the first line arrives at once and the rest is cut off by `head`-like
    /// early exit (the process is terminated once a line has been read). Low-volume messages such as the shutdown cause
    /// usually expire sooner than this, since the log rotates its busiest files first.
    public static func oldestEntry(days: Int = 60) -> Date? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["show", "--style", "ndjson", "--last", "\(days)d"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timer)
        var buf = Data()
        // Read until the first complete event line (the first line can be a banner or a header in some versions).
        while buf.count < 1_000_000 {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buf.append(chunk)
            // Any event line will do (most are default-level, which LogParser skips), so only the timestamp is read.
            let stamp = String(decoding: buf, as: UTF8.self).split(separator: "\n").lazy.compactMap { line -> Date? in
                guard let r = line.range(of: #""timestamp":"[^"]+""#, options: .regularExpression) else { return nil }
                return LogParser.parseTimestamp(String(line[r].dropFirst(13).dropLast()))
            }.first
            if let stamp {
                p.terminate(); timer.cancel(); p.waitUntilExit()
                return stamp
            }
        }
        if p.isRunning { p.terminate() }
        timer.cancel(); p.waitUntilExit()
        return nil
    }
}
