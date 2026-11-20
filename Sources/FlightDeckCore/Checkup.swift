import Foundation

// The Checkup destination: a one-screen health and security checklist. Each check reads one fact from a command-line
// tool, a world-readable preferences plist or IOKit, and turns it into pass / attention / unknown with a plain-English
// explanation. Nothing here needs root: anything that does, or that can't be read, comes back as `unknown` with the
// reason rather than a guess. The parsers are pure functions (tested with captured tool output); `Checkup.run` does
// the I/O and is called off the main thread only when the page is opened or refreshed.

/// One row of the checklist.
public struct CheckResult: Identifiable, Sendable, Hashable {
    public enum Status: String, Sendable, Hashable { case pass = "OK", attention = "Attention", unknown = "Unknown" }
    /// Where the user can fix or review it: a System Settings pane (an `x-apple.systempreferences:` URL) or a
    /// FlightDeck destination (a navigation key such as "Flight Log").
    public enum Fix: Sendable, Hashable {
        case settings(label: String, url: String)
        case app(label: String, destination: String)
    }
    public var id: String
    public var group: String
    public var title: String
    public var status: Status
    /// Short value shown next to the title ("On", "3 days ago").
    public var value: String
    /// What this means and why it matters, in plain English. For `unknown`, the reason it couldn't be determined.
    public var detail: String
    public var fixes: [Fix] = []

    public init(id: String, group: String, title: String, status: Status, value: String, detail: String, fixes: [Fix] = []) {
        self.id = id; self.group = group; self.title = title; self.status = status; self.value = value; self.detail = detail; self.fixes = fixes
    }
}

/// System Settings deep links (the pane identifiers macOS 13+ registers). Opening one never changes a setting.
public enum SettingsPane {
    public static let privacySecurity = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    public static let fileVault = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault"
    public static let firewall = "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"
    public static let softwareUpdate = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
    public static let timeMachine = "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"
    public static let storage = "x-apple.systempreferences:com.apple.settings.Storage"
    public static let battery = "x-apple.systempreferences:com.apple.Battery-Settings.extension"
    public static let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
}

// MARK: - Parsers (pure; unit-tested with captured output)

public enum CheckupParse {
    public enum FileVault: Equatable { case on, off, encrypting(Int?), decrypting(Int?), unknown }

    /// `fdesetup status`: "FileVault is On." / "FileVault is Off." / "Encryption in progress: Percent completed = 34".
    public static func fileVault(_ out: String) -> FileVault {
        func percent() -> Int? {
            guard let r = out.range(of: "Percent completed = ") else { return nil }
            return Int(out[r.upperBound...].prefix { $0.isNumber })
        }
        if out.contains("Encryption in progress") { return .encrypting(percent()) }
        if out.contains("Decryption in progress") { return .decrypting(percent()) }
        if out.contains("FileVault is On") { return .on }
        if out.contains("FileVault is Off") { return .off }
        return .unknown
    }

    /// `spctl --status`: "assessments enabled" / "assessments disabled". nil if neither.
    public static func gatekeeper(_ out: String) -> Bool? {
        if out.contains("assessments enabled") { return true }
        if out.contains("assessments disabled") { return false }
        return nil
    }

    /// `socketfilterfw --getglobalstate`: "Firewall is enabled. (State = 1)", "... (State = 2)" (block all incoming),
    /// "Firewall is disabled. (State = 0)". Returns the state number, nil if absent.
    public static func firewallState(_ out: String) -> Int? {
        if let r = out.range(of: "State = "), let n = Int(out[r.upperBound...].prefix { $0.isNumber }) { return n }
        if out.contains("Firewall is enabled") { return 1 }
        if out.contains("Firewall is disabled") { return 0 }
        return nil
    }

    /// `socketfilterfw --getstealthmode`: "Firewall stealth mode is on|off". nil if neither.
    public static func stealthMode(_ out: String) -> Bool? {
        if out.contains("stealth mode is on") { return true }
        if out.contains("stealth mode is off") { return false }
        return nil
    }

    /// `system_profiler -json SPiBridgeDataType`. Despite the name this data type also exists on Apple silicon, where it
    /// reports the boot policy without root: "ibridge_secure_boot" is "Full Security", "Reduced Security" or
    /// "Permissive Security"; "ibridge_sb_other_kext" says whether third-party kernel extensions may load.
    public static func secureBoot(_ json: Data) -> (level: String, otherKexts: Bool?)? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let items = root["SPiBridgeDataType"] as? [[String: Any]],
              let level = items.lazy.compactMap({ $0["ibridge_secure_boot"] as? String }).first else { return nil }
        let kext = items.lazy.compactMap { $0["ibridge_sb_other_kext"] as? String }.first.map { $0 == "Yes" }
        return (level, kext)
    }

    /// The software-update settings and macOS's own cached scan result, from /Library/Preferences/com.apple.SoftwareUpdate
    /// (world-readable). Absent keys mean the setting was never changed from macOS's default.
    public struct UpdatePrefs: Equatable {
        public var automaticCheck: Bool?
        public var automaticDownload: Bool?
        /// "Install Security Responses and system files" (critical updates + XProtect/config data).
        public var criticalUpdateInstall: Bool?
        public var configDataInstall: Bool?
        public var installMacOSUpdates: Bool?
        /// Display names of updates macOS found at its last check, and when that check happened.
        public var recommended: [String]
        public var lastCheck: Date?
    }

    public static func updatePrefs(_ d: [String: Any]) -> UpdatePrefs {
        UpdatePrefs(automaticCheck: d["AutomaticCheckEnabled"] as? Bool, automaticDownload: d["AutomaticDownload"] as? Bool,
                    criticalUpdateInstall: d["CriticalUpdateInstall"] as? Bool, configDataInstall: d["ConfigDataInstall"] as? Bool,
                    installMacOSUpdates: d["AutomaticallyInstallMacOSUpdates"] as? Bool,
                    recommended: (d["RecommendedUpdates"] as? [[String: Any]] ?? []).compactMap { $0["Display Name"] as? String },
                    lastCheck: (d["LastSuccessfulDate"] as? Date) ?? (d["LastFullSuccessfulDate"] as? Date))
    }

    /// `softwareupdate --list` (stdout and stderr merged: "No new software available." goes to stderr). Returns the
    /// Title of each "* Label:" entry, [] for "No new software available", nil if the output is neither (e.g. offline).
    public static func softwareUpdateList(_ out: String) -> [String]? {
        if out.contains("No new software available") { return [] }
        guard out.contains("* Label:") else { return nil }
        var titles: [String] = []
        for line in out.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("* Label:") { titles.append(String(l.dropFirst(8)).trimmingCharacters(in: .whitespaces)) }
            // The detail line after a label: "Title: macOS 26.2, Version: 26.2, Size: …"; prefer the title when present.
            else if l.hasPrefix("Title:"), !titles.isEmpty {
                titles[titles.count - 1] = l.dropFirst(6).split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? titles[titles.count - 1]
            }
        }
        return titles
    }

    /// Time Machine settings from /Library/Preferences/com.apple.TimeMachine (world-readable, unlike `tmutil` for some
    /// queries, and readable while the backup disk is disconnected). The latest backup is the newest of every
    /// destination's SnapshotDates.
    public struct TimeMachine: Equatable {
        public var autoBackup: Bool?
        public var destinations: Int
        public var latest: Date?
    }

    /// Parsed by BackupParse.prefs, which the Backups page shares.
    public static func timeMachine(_ d: [String: Any]) -> TimeMachine { timeMachine(prefs: BackupParse.prefs(d)) }

    /// `tmutil latestbackup` prints a path ending in "YYYY-MM-DD-HHMMSS.backup" (or a bare "YYYY-MM-DD-HHMMSS" folder on
    /// HFS+ destinations). The timestamp is local time.
    public static func tmutilLatest(_ out: String) -> Date? {
        guard let last = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").last else { return nil }
        let stamp = String(last.replacingOccurrences(of: ".backup", with: "").suffix(17))
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: stamp)
    }

    /// One entry of `systemextensionsctl list`.
    public struct SystemExtension: Equatable, Hashable, Sendable {
        public var teamID: String
        public var bundleID: String
        public var name: String
        public var state: String
        public var enabled: Bool
        public var active: Bool
    }

    /// `systemextensionsctl list`: category headers ("--- com.apple.system_extension.…"), a column header, then
    /// tab-separated rows "enabled  active  teamID  bundleID (version)  name  [state]" where enabled/active are "*" or
    /// empty. Apple's own extensions use teamID "-" or "Apple"; they are kept here and filtered by the caller.
    public static func systemExtensions(_ out: String) -> [SystemExtension] {
        out.split(separator: "\n").compactMap { line -> SystemExtension? in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard c.count >= 6, c[0] != "enabled", let s = c.last, s.hasPrefix("[") else { return nil }
            let bundle = c[3].split(separator: " ").first.map(String.init) ?? c[3]
            return SystemExtension(teamID: c[2], bundleID: bundle, name: c[4], state: String(s.dropFirst().dropLast()),
                                   enabled: c[0] == "*", active: c[1] == "*")
        }
    }

    /// `kmutil showloaded --list-only`: "Index Refs Address Size Wired Name (Version) UUID <Linked Against>". Returns the
    /// bundle IDs of loaded kernel extensions that aren't Apple's (not "com.apple.*"), with their versions.
    public static func thirdPartyKexts(_ out: String) -> [String] {
        out.split(separator: "\n").compactMap { line in
            let t = line.split(whereSeparator: \.isWhitespace).map(String.init)
            // the name is the token just before "(version)"
            guard let v = t.firstIndex(where: { $0.hasPrefix("(") && $0.hasSuffix(")") }), v > 0, Int(t[0]) != nil else { return nil }
            let name = t[v - 1]
            return name.hasPrefix("com.apple.") ? nil : "\(name) \(t[v])"
        }
    }

    /// `system_profiler -json SPPowerDataType`: battery condition ("Good", "Service Recommended", …), maximum capacity
    /// ("87%") and cycle count. nil when there's no battery section (desktop Macs).
    public struct Battery: Equatable { public var condition: String?; public var maxCapacity: String?; public var cycles: Int? }

    public static func battery(_ json: Data) -> Battery? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]],
              let b = items.first(where: { ($0["_name"] as? String) == "spbattery_information" }) else { return nil }
        let h = b["sppower_battery_health_info"] as? [String: Any] ?? [:]
        return Battery(condition: h["sppower_battery_health"] as? String, maxCapacity: h["sppower_battery_health_maximum_capacity"] as? String,
                       cycles: (h["sppower_battery_cycle_count"] as? NSNumber)?.intValue)
    }
}
