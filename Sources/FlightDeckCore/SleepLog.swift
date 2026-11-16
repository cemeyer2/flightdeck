import Foundation

// Backs the Sleep & Wake view (SleepView). pmset's log is the only no-root source that records sleep/wake transitions
// with their reasons, battery charge and assertion history; it is parsed on demand, never per tick.
/// Sleep and wake history from `pmset -g log` (no root needed): when the Mac slept, every wake and its
/// reason, what each sleep cost in battery, who scheduled wakes, and who kept the Mac awake.
public struct SleepEvent: Sendable, Hashable, Identifiable {
    /// Sleep = entered sleep; dark wake = woke briefly with the display off (Power Nap, network upkeep, timers);
    /// wake = full user-visible wake.
    public enum Kind: String, Sendable { case sleep = "Sleep", darkWake = "Dark wake", wake = "Wake" }
    public var id: Date { time }
    public var time: Date
    public var kind: Kind
    public var reason: String          // raw reason from the log
    /// From the log's "Using BATT"/"Using AC" suffix; nil when the line doesn't say. `charge` is the battery % at that moment.
    public var onBattery: Bool?
    public var charge: Int?
    public var seconds: Int?           // how long this state lasted (sleep: asleep; dark wake: awake in the dark)
    public var explanation: String { SleepLog.explain(reason, kind: kind) }
}

/// One user-level sleep: from a "real" sleep until the next full wake, with the dark wakes in between.
public struct SleepSession: Sendable, Hashable, Identifiable {
    public var id: Date { start }
    public var start: Date, end: Date
    public var why: String                       // why it went to sleep (lid closed, idle…)
    public var wokeBy: String                    // what finally woke it
    public var darkWakes: [SleepEvent]
    public var asleepSeconds: Int                // time actually asleep (excludes dark wakes)
    public var chargeStart: Int?, chargeEnd: Int?
    public var onBatteryThroughout: Bool
    /// Charge points lost while asleep. Only meaningful when the Mac stayed on battery the whole time (charging would
    /// hide the drain), so nil otherwise; clamped at 0 in case the reading rose.
    public var batteryUsed: Int? { onBatteryThroughout ? chargeStart.flatMap { s in chargeEnd.map { max(s - $0, 0) } } : nil }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Parsed result for the requested window. `sessions` is newest first; the three tallies are sorted by count/seconds.
/// `keptAwake` is the union of sleep-preventing assertion time per process (overlapping assertions counted once).
public struct SleepReport: Sendable {
    public var events: [SleepEvent]
    public var sessions: [SleepSession]
    public var darkWakeReasons: [(reason: String, count: Int)]
    public var wakeRequesters: [(process: String, count: Int)]
    public var keptAwake: [(process: String, seconds: Int, reason: String)]
}

public enum SleepLog {
    /// pmset timestamps look like "2026-11-16 00:10:00 -0600". The POSIX locale keeps parsing independent of user settings.
    static let stamp: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"; return f }()

    /// Runs `pmset -g log` (it can be many MB and take seconds, hence the 20 s timeout) and parses the last `days` days.
    /// Blocks; call off the main thread. nil if pmset couldn't be run.
    public static func read(days: Double = 3) -> SleepReport? {
        guard let out = Shell.run("/usr/bin/pmset", ["-g", "log"], timeout: 20) else { return nil }
        return parse(out, since: Date().addingTimeInterval(-days * 86_400))
    }

    /// Plain-English meaning of a wake/sleep reason.
    /// Matching is on lowercased substrings because the reason text varies across macOS versions and hardware (Intel
    /// wake reasons name ACPI devices, Apple silicon ones name SMC/SPMI interrupts). Order matters: the more specific
    /// phrases are tested before generic ones such as "rtc". Unknown reasons are shown verbatim.
    public static func explain(_ r: String, kind: SleepEvent.Kind) -> String {
        let s = r.lowercased()
        if kind == .sleep {
            if s.contains("clamshell") { return "Lid closed" }
            if s.contains("idle sleep") { return "Idle" }
            if s.contains("maintenance sleep") || s.contains("sleep service back") || s.contains("notification wake back") { return "Back to sleep after a dark wake" }
            if s.contains("software sleep") || s.contains("apple menu") { return "Sleep chosen from the menu" }
            if s.contains("power button") { return "Power button" }
            if s.contains("low power") || s.contains("battery") { return "Low battery" }
            return r
        }
        if s.contains("hid activity") || s.contains("useractivity") || s.contains("user activity") { return "You (keyboard, trackpad or mouse)" }
        if s.contains("lidopen") || s.contains("lid open") { return "Lid opened" }
        if s.contains("acdetach") { return "Power adapter disconnected" }
        if s.contains("usb-c_plug") || s.contains("acattach") || s.contains("power adapter") { return "Power adapter connected" }
        if s.contains("powerbutton") || s.contains("power button") { return "Power button" }
        if s.contains("rtc/maintenance") || s.hasSuffix("maintenance") { return "Scheduled maintenance (network upkeep, Power Nap)" }
        if s.contains("sleepservice") { return "Sleep services (background tasks)" }
        if s.contains("notification") { return "A notification" }
        if s.contains("bluetooth") { return "Bluetooth" }
        if s.contains("e_rx_ip_packet") { return "Network traffic arrived (Wi-Fi)" }
        if s.contains("e_connection_loss") || s.contains("e_disassoc") { return "Wi-Fi connection dropped" }
        if s.contains("wifibt") || s.contains("arpt") || s.contains("wlan") { return "Wi-Fi" }
        if s.contains("nub.spmi") || s.contains("rtc") { return "Timer (scheduled wake)" }
        return r.trimmingCharacters(in: .whitespaces)
    }

    /// Total time covered by possibly overlapping intervals.
    /// Classic interval merge: sort by start, extend the current run while intervals overlap, add each finished run.
    static func unionLength(_ iv: [(Date, Date)]) -> TimeInterval {
        var total = 0.0; var cur: (Date, Date)?
        for i in iv.sorted(by: { $0.0 < $1.0 }) {
            if let c = cur, i.0 <= c.1 { cur = (c.0, max(c.1, i.1)) } else { if let c = cur { total += c.1.timeIntervalSince(c.0) }; cur = i }
        }
        if let c = cur { total += c.1.timeIntervalSince(c.0) }
        return total
    }

    /// Parses pmset log text, keeping lines at or after `since`. Exposed separately from read() so tests can feed fixtures.
    public static func parse(_ text: String, since: Date) -> SleepReport {
        var events: [SleepEvent] = []
        var requesters: [String: Int] = [:]
        var awakeIntervals: [String: [(Date, Date)]] = [:]
        var awakeReason: [String: String] = [:]
        for line in text.split(separator: "\n") {
            // Each line is a 25-character timestamp, a space, a padded event type, a tab, then the message. Lines without a valid
            // timestamp (headers, wrapped continuation lines) are skipped.
            guard line.count > 26, let t = stamp.date(from: String(line.prefix(25))), t >= since else { continue }
            let body = line.dropFirst(26)
            let tab = body.firstIndex(of: "\t") ?? body.endIndex
            let type = body[..<tab].trimmingCharacters(in: .whitespaces)
            let msg = tab < body.endIndex ? String(body[body.index(after: tab)...]) : ""
            switch type {
            case "Sleep", "DarkWake", "Wake":
                let kind: SleepEvent.Kind = type == "Sleep" ? .sleep : type == "DarkWake" ? .darkWake : .wake
                var reason = ""
                // The reason is the text after "due to " up to the "Using AC/BATT" suffix, with quotes and the
                // ":TCPKeepAlive=..."
                // tail removed (e.g. "'Clamshell Sleep':TCPKeepAlive=active" becomes "Clamshell Sleep").
                if let r = msg.range(of: "due to ") {
                    let after = msg[r.upperBound...]
                    let end = after.range(of: "Using ")?.lowerBound ?? after.endIndex
                    reason = after[..<end].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "'", with: "")
                    if let colon = reason.range(of: ":TCPKeepAlive") { reason = String(reason[..<colon.lowerBound]) }
                    if reason.hasSuffix("/") { reason.removeLast() }
                }
                let battery: Bool? = msg.contains("Using BATT") ? true : msg.contains("Using AC") ? false : nil
                let charge = msg.range(of: #"Charge:(\d+)%"#, options: .regularExpression).flatMap { Int(msg[$0].dropFirst(7).dropLast()) }
                // The trailing "N secs" is how long the state lasted (pmset appends it once the next transition happens).
                let secs = msg.range(of: #"(\d+) secs"#, options: .regularExpression).flatMap { Int(msg[$0].split(separator: " ")[0]) }
                events.append(SleepEvent(time: t, kind: kind, reason: reason, onBattery: battery, charge: charge, seconds: secs))
            // Lists the scheduled wakes requested before sleeping; each "process=NAME request=..." counts toward that process.
            case "Wake Requests":
                for m in msg.matches(of: #/process=([^ ]+) request=/#) { requesters[String(m.1), default: 0] += 1 }
            case "Assertions":
                // "PID 883(Google Chrome) Released PreventUserIdleSystemSleep "reason" 00:12:03 …"
                if let m = msg.firstMatch(of: #/PID \d+\((.+?)\) Released (\w+) "(.*?)" (\d\d):(\d\d):(\d\d)/#),
                   ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"].contains(String(m.2)),
                   let h = Int(m.4), let mi = Int(m.5), let se = Int(m.6) {
                    // interval [release - held, release], clipped to the window; overlaps are merged below
                    let held = TimeInterval(h * 3600 + mi * 60 + se)
                    awakeIntervals[String(m.1), default: []].append((max(t.addingTimeInterval(-held), since), t))
                    if (awakeReason[String(m.1)] ?? "").isEmpty { awakeReason[String(m.1)] = String(m.3) }
                }
            default: break
            }
        }
        // Sessions: a real sleep (not "back to sleep") until the next full wake.
        var sessions: [SleepSession] = []
        // A Sleep while a session is open is a "back to sleep" after a dark wake: it adds asleep time but doesn't start a new
        // session. Seeing AC at any point marks the session as not on battery throughout. Dark wakes and sleeps before the
        // first Sleep in the window are ignored, and a session with no closing Wake yet is dropped.
        var cur: (start: SleepEvent, dark: [SleepEvent], asleep: Int, battery: Bool)?
        for e in events {
            switch e.kind {
            case .sleep:
                if cur == nil { cur = (e, [], 0, e.onBattery ?? false) }
                cur!.asleep += e.seconds ?? 0
                if e.onBattery == false { cur!.battery = false }
            case .darkWake:
                if cur != nil { cur!.dark.append(e); if e.onBattery == false { cur!.battery = false } }
            case .wake:
                if let c = cur {
                    sessions.append(SleepSession(start: c.start.time, end: e.time, why: c.start.explanation, wokeBy: e.explanation,
                                                 darkWakes: c.dark, asleepSeconds: c.asleep, chargeStart: c.start.charge, chargeEnd: e.charge,
                                                 onBatteryThroughout: c.battery && (e.onBattery ?? true)))
                }
                cur = nil
            }
        }
        let darkReasons = Dictionary(grouping: events.filter { $0.kind == .darkWake }, by: \.explanation).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        return SleepReport(events: events, sessions: sessions.reversed(), darkWakeReasons: darkReasons,
                           wakeRequesters: requesters.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 },
                           keptAwake: awakeIntervals.map { name, iv in (name, Int(unionLength(iv)), awakeReason[name] ?? "") }.sorted { $0.1 > $1.1 })
    }
}
