import Foundation

// Turns parsed facts into Checkup rows. Kept separate from the I/O in CheckupRun.swift so the verdicts and their wording
// can be tested with fixed inputs. Thresholds are judgement calls, stated in each row's explanation.

public enum CheckupRules {
    static let security = "Security", updates = "Updates & backup", hardware = "Storage & hardware", stability = "Stability", startup = "Startup & extensions"

    /// A coarse, readable time span for explanations: "45 minutes", "5 hours", "3 days".
    static func span(_ s: TimeInterval) -> String {
        let m = Int(max(s, 0) / 60)
        if m < 120 { return m == 1 ? "1 minute" : "\(m) minutes" }
        let h = m / 60
        if h < 48 { return "\(h) hours" }
        return "\(h / 24) days"
    }

    static func unknown(_ id: String, _ group: String, _ title: String, _ why: String, fixes: [CheckResult.Fix] = []) -> CheckResult {
        CheckResult(id: id, group: group, title: title, status: .unknown, value: "Unknown", detail: why, fixes: fixes)
    }

    public static func sip(_ csr: String?) -> CheckResult {
        let t = "System Integrity Protection"
        guard let csr else { return unknown("sip", security, t, "csrutil could not be run.") }
        switch SystemInfo.parseCSR(csr) {
        case "Enabled":
            return CheckResult(id: "sip", group: security, title: t, status: .pass, value: "On",
                               detail: "SIP stops any process, even one running as root, from changing macOS's own files.")
        case "Disabled":
            return CheckResult(id: "sip", group: security, title: t, status: .attention, value: "Off",
                               detail: "SIP is turned off, so malware running as root could modify macOS itself. It can only be turned back on from macOS Recovery (Terminal: csrutil enable).")
        case "Custom configuration":
            return CheckResult(id: "sip", group: security, title: t, status: .attention, value: "Custom",
                               detail: "Some SIP protections have been turned off. Restore them from macOS Recovery (Terminal: csrutil enable).")
        default:
            return unknown("sip", security, t, "csrutil's output wasn't recognised.")
        }
    }

    public static func fileVault(_ out: String?) -> CheckResult {
        let t = "FileVault disk encryption", fix = [CheckResult.Fix.settings(label: "FileVault Settings", url: SettingsPane.fileVault)]
        guard let out else { return unknown("filevault", security, t, "fdesetup could not be run.", fixes: fix) }
        switch CheckupParse.fileVault(out) {
        case .on: return CheckResult(id: "filevault", group: security, title: t, status: .pass, value: "On",
                                     detail: "The startup disk is encrypted, so a lost or stolen Mac's data can't be read without your password.", fixes: fix)
        case .off: return CheckResult(id: "filevault", group: security, title: t, status: .attention, value: "Off",
                                      detail: "The startup disk isn't encrypted: anyone with the Mac could read its files. Turning FileVault on encrypts in the background.", fixes: fix)
        case .encrypting(let p): return CheckResult(id: "filevault", group: security, title: t, status: .pass, value: "Encrypting" + (p.map { " (\($0)%)" } ?? ""),
                                                    detail: "FileVault is encrypting the startup disk in the background.", fixes: fix)
        case .decrypting(let p): return CheckResult(id: "filevault", group: security, title: t, status: .attention, value: "Decrypting" + (p.map { " (\($0)%)" } ?? ""),
                                                    detail: "FileVault is being turned off and the disk is being decrypted.", fixes: fix)
        case .unknown: return unknown("filevault", security, t, "fdesetup's output wasn't recognised.", fixes: fix)
        }
    }

    public static func gatekeeper(_ out: String?) -> CheckResult {
        let t = "Gatekeeper", fix = [CheckResult.Fix.settings(label: "Privacy & Security", url: SettingsPane.privacySecurity)]
        switch out.flatMap(CheckupParse.gatekeeper) {
        case true?: return CheckResult(id: "gatekeeper", group: security, title: t, status: .pass, value: "On",
                                       detail: "macOS checks that downloaded apps are signed and notarized before opening them.", fixes: fix)
        case false?: return CheckResult(id: "gatekeeper", group: security, title: t, status: .attention, value: "Off",
                                        detail: "App assessments are disabled, so unsigned or unnotarized downloads open without warning. Re-enable with `spctl --global-enable` (asks for an administrator password).", fixes: fix)
        case nil: return unknown("gatekeeper", security, t, "spctl --status gave no recognisable answer.", fixes: fix)
        }
    }

    public static func firewall(state: String?, stealth: String?) -> CheckResult {
        let t = "Application firewall", fix = [CheckResult.Fix.settings(label: "Firewall Settings", url: SettingsPane.firewall)]
        guard let s = state.flatMap(CheckupParse.firewallState) else { return unknown("firewall", security, t, "socketfilterfw gave no recognisable answer.", fixes: fix) }
        let st = stealth.flatMap(CheckupParse.stealthMode)
        let stealthText = st.map { $0 ? " Stealth mode is on (the Mac ignores pings and probes)." : " Stealth mode is off." } ?? ""
        if s == 0 {
            return CheckResult(id: "firewall", group: security, title: t, status: .attention, value: "Off",
                               detail: "Incoming connections to sharing services and apps aren't filtered. Off is macOS's default; turn it on if you use public or shared networks." + stealthText, fixes: fix)
        }
        return CheckResult(id: "firewall", group: security, title: t, status: .pass, value: s == 2 ? "On (block all)" : "On",
                           detail: (s == 2 ? "All incoming connections are blocked except essential services." : "Incoming connections are only allowed for apps you've approved.") + stealthText, fixes: fix)
    }

    public static func secureBoot(_ sb: (level: String, otherKexts: Bool?)?) -> CheckResult {
        let t = "Startup security"
        guard let sb else { return unknown("secureboot", security, t, "This Mac doesn't report its boot policy without root (Intel Macs without a T2 chip have no secure boot; Apple silicon's bputil needs root).") }
        let kext = sb.otherKexts == true ? " Third-party kernel extensions are allowed to load." : ""
        if sb.level.hasPrefix("Full") {
            return CheckResult(id: "secureboot", group: security, title: t, status: .pass, value: sb.level,
                               detail: "The Mac only starts a macOS version Apple currently signs, with the strongest protection." + kext)
        }
        return CheckResult(id: "secureboot", group: security, title: t, status: .attention, value: sb.level,
                           detail: "Startup security was lowered from Full Security (usually to allow kernel extensions or older macOS versions)." + kext + " It can only be changed in macOS Recovery › Startup Security Utility.")
    }

    public static func autoUpdates(_ p: CheckupParse.UpdatePrefs?) -> CheckResult {
        let t = "Automatic security updates", fix = [CheckResult.Fix.settings(label: "Software Update", url: SettingsPane.softwareUpdate)]
        guard let p else { return unknown("autoupdate", updates, t, "The Software Update preferences couldn't be read.", fixes: fix) }
        // An absent key means the setting was never changed; macOS's default for each of these is on.
        func state(_ v: Bool?) -> String { v.map { $0 ? "on" : "off" } ?? "on (default)" }
        let lines = "Check for updates: \(state(p.automaticCheck)). Security Responses and system files: \(state(p.criticalUpdateInstall)). Download new updates: \(state(p.automaticDownload))."
        let ok = p.automaticCheck != false && p.criticalUpdateInstall != false && p.configDataInstall != false
        return CheckResult(id: "autoupdate", group: updates, title: t, status: ok ? .pass : .attention, value: ok ? "On" : "Off",
                           detail: (ok ? "macOS installs security fixes and malware definitions automatically. " : "Some automatic security updates are turned off, so fixes and malware definitions may be late. ") + lines, fixes: fix)
    }

    /// `live` is the result of a `softwareupdate --list` run (on button press), which overrides macOS's cached result.
    public static func pendingUpdates(_ p: CheckupParse.UpdatePrefs?, live: [String]?, liveError: String?, now: Date = Date()) -> CheckResult {
        let t = "Pending software updates", fix = [CheckResult.Fix.settings(label: "Software Update", url: SettingsPane.softwareUpdate)]
        let names: [String], source: String
        if let live { names = live; source = "Checked just now." }
        else if let p, let last = p.lastCheck {
            names = p.recommended
            source = "As of macOS's last check, \(span(now.timeIntervalSince(last))) ago. Press Check Now to ask Apple's servers (slow)."
        } else {
            return unknown("pending", updates, t, (liveError ?? "macOS hasn't recorded an update check.") + " Press Check Now to ask Apple's servers.", fixes: fix)
        }
        if names.isEmpty { return CheckResult(id: "pending", group: updates, title: t, status: .pass, value: "Up to date", detail: "No updates are waiting. " + source, fixes: fix) }
        return CheckResult(id: "pending", group: updates, title: t, status: .attention, value: "\(names.count) available",
                           detail: names.joined(separator: ", ") + ". " + source, fixes: fix)
    }

    public static func timeMachine(_ tm: CheckupParse.TimeMachine?, tmutil: Date?, now: Date = Date()) -> CheckResult {
        let t = "Time Machine backup", fix = [CheckResult.Fix.settings(label: "Time Machine Settings", url: SettingsPane.timeMachine)]
        let latest = [tm?.latest, tmutil].compactMap { $0 }.max()
        if tm?.destinations == 0 && latest == nil {
            return CheckResult(id: "timemachine", group: updates, title: t, status: .attention, value: "Not set up",
                               detail: "No backup disk is configured. Without a backup a failed drive or deleted file can't be recovered.", fixes: fix)
        }
        guard let latest else { return unknown("timemachine", updates, t, "No completed backup date could be read (Time Machine preferences and tmutil had none).", fixes: fix) }
        let age = now.timeIntervalSince(latest)
        let auto = tm?.autoBackup == false ? " Automatic backups are turned off." : ""
        // More than 3 days without a backup is flagged: Time Machine normally backs up hourly or daily.
        return CheckResult(id: "timemachine", group: updates, title: t, status: age > 3 * 86_400 || tm?.autoBackup == false ? .attention : .pass,
                           value: span(max(age, 0)) + " ago",
                           detail: "Last completed backup: \(latest.formatted(date: .abbreviated, time: .shortened))." + auto, fixes: fix)
    }

    public static func freeSpace(_ v: VolumeInfo?) -> CheckResult {
        let t = "Free disk space", fix: [CheckResult.Fix] = [.app(label: "Disk Space", destination: "Disk Space"), .settings(label: "Storage Settings", url: SettingsPane.storage)]
        guard let v, v.capacity > 0 else { return unknown("diskspace", hardware, t, "The startup volume's capacity couldn't be read.", fixes: fix) }
        let frac = Double(v.available) / Double(v.capacity)
        // Below 10% or 15 GB macOS starts struggling: swap, updates and caches all need room.
        let low = frac < 0.10 || v.available < 15_000_000_000
        return CheckResult(id: "diskspace", group: hardware, title: t, status: low ? .attention : .pass,
                           value: "\(Fmt.bytes(Double(v.available))) free (\(Int(frac * 100))%)",
                           detail: low ? "The startup disk is nearly full. macOS needs free space for swap, updates and caches, and slows down without it."
                                       : "Enough room on the startup disk for swap, updates and caches.", fixes: fix)
    }

    public static func drives(_ d: [DriveHealth]) -> CheckResult {
        let t = "Drive health (SMART)"
        guard !d.isEmpty else { return unknown("smart", hardware, t, "No NVMe SMART data is readable (the drive isn't NVMe, or this Mac doesn't expose its health log).") }
        let bad = d.filter { !$0.healthy }
        if bad.isEmpty {
            return CheckResult(id: "smart", group: hardware, title: t, status: .pass, value: "Healthy",
                               detail: d.map { "\($0.model): \($0.percentUsed)% of rated endurance used, \($0.availableSpare)% spare, no media errors." }.joined(separator: " "))
        }
        return CheckResult(id: "smart", group: hardware, title: t, status: .attention, value: "Warning",
                           detail: bad.map { "\($0.model): " + $0.warnings.joined(separator: ", ") + "." }.joined(separator: " ") + " Back up now.")
    }

    public static func battery(_ b: CheckupParse.Battery?, hasBattery: Bool) -> CheckResult {
        let t = "Battery condition", fix = [CheckResult.Fix.settings(label: "Battery Settings", url: SettingsPane.battery)]
        guard hasBattery else { return unknown("battery", hardware, t, "This Mac has no battery.") }
        guard let b, let c = b.condition else { return unknown("battery", hardware, t, "system_profiler didn't report the battery's condition.", fixes: fix) }
        let facts = [b.maxCapacity.map { "maximum capacity \($0)" }, b.cycles.map { "\($0) charge cycles" }].compactMap { $0 }.joined(separator: ", ")
        let ok = c == "Good" || c == "Normal"
        return CheckResult(id: "battery", group: hardware, title: t, status: ok ? .pass : .attention, value: c,
                           detail: (ok ? "macOS rates the battery as working normally" : "macOS recommends having the battery checked or serviced")
                               + (facts.isEmpty ? "." : " (\(facts))."), fixes: fix)
    }

    public static func reports(_ r: [DiagnosticReport], days: Int = 7) -> CheckResult {
        let t = "Crashes and hangs (\(days) days)", fix = [CheckResult.Fix.app(label: "Flight Log", destination: "Flight Log")]
        let crashes = r.filter { $0.kind == .crash }, hangs = r.filter { $0.kind == .hang }
        let panics = r.filter { $0.kind == .panic }.count, jetsam = r.filter { $0.kind == .jetsam }.count
        let byApp = Dictionary(grouping: crashes + hangs, by: \.process).mapValues(\.count)
        let worst = byApp.max { $0.value < $1.value }
        func n(_ c: Int, _ w: String) -> String { "\(c) \(w)" + (c == 1 ? "" : (w.hasSuffix("h") ? "es" : "s")) }
        var parts = [n(crashes.count, "crash"), n(hangs.count, "hang")]
        if panics > 0 { parts.append(n(panics, "kernel panic")) }
        if jetsam > 0 { parts.append(n(jetsam, "memory kill")) }
        // Any kernel panic, an app failing 3+ times, or 10+ in total is worth a look.
        let bad = panics > 0 || (worst?.value ?? 0) >= 3 || crashes.count + hangs.count >= 10
        let detail = parts.joined(separator: ", ") + " in macOS's reports."
            + (worst.map { $0.value >= 2 ? " Most often: \($0.key) (\($0.value))." : "" } ?? "")
            + (panics > 0 ? " A kernel panic restarts the whole Mac; repeated panics usually mean faulty hardware or a kernel extension." : "")
        return CheckResult(id: "reports", group: stability, title: t, status: bad ? .attention : .pass,
                           value: "\(crashes.count + hangs.count + panics)", detail: detail, fixes: fix)
    }

    public static func uptime(boot: Date?, now: Date = Date()) -> CheckResult {
        let t = "Uptime"
        guard let boot else { return unknown("uptime", stability, t, "kern.boottime couldn't be read.") }
        let up = now.timeIntervalSince(boot)
        let long = up > 30 * 86_400
        return CheckResult(id: "uptime", group: stability, title: t, status: long ? .attention : .pass, value: span(up),
                           detail: long ? "Running for over 30 days. A restart installs pending updates and clears leaked memory and stuck background processes."
                                        : "Restarted recently enough; no restart needed.")
    }

    /// `history` is (time, swap bytes in use) from the black box, oldest first; `current` is vm.swapusage now.
    public static func swap(current: Double?, history: [(Date, Double)], ram: Double?) -> CheckResult {
        let t = "Swap usage", fix = [CheckResult.Fix.app(label: "Memory", destination: "Performance:Memory")]
        guard let current else { return unknown("swap", stability, t, "vm.swapusage couldn't be read.", fixes: fix) }
        var trend = "No black-box history to show a trend (the black box is off or has under 2 hours of data)."
        var growth: Double?
        if let first = history.first, let last = history.last, last.0.timeIntervalSince(first.0) >= 7200 {
            growth = current - first.1
            let hours = Int(Date().timeIntervalSince(first.0) / 3600)
            trend = "\(Fmt.bytes(first.1)) \(hours) h ago, peak \(Fmt.bytes(history.map(\.1).max() ?? current))."
        }
        // Growing by 1 GB+ to 2 GB+, or above half of RAM, means memory is regularly short.
        let bad = ((growth ?? 0) >= 1e9 && current >= 2e9) || (ram.map { current >= $0 / 2 } ?? false)
        return CheckResult(id: "swap", group: stability, title: t, status: bad ? .attention : .pass, value: Fmt.bytes(current) + " now",
                           detail: (bad ? "The Mac is swapping heavily: memory is regularly short, which slows everything down. " : "Swap use is modest. ") + trend, fixes: fix)
    }

    public static func startupItems(_ items: [StartupItem]?) -> CheckResult {
        let t = "Login and background items", fix: [CheckResult.Fix] = [.app(label: "Startup Apps", destination: "Startup Apps"), .settings(label: "Login Items", url: SettingsPane.loginItems)]
        guard let items else { return unknown("startup", startup, t, "The LaunchAgents/LaunchDaemons folders couldn't be read.", fixes: fix) }
        let third = items.filter { $0.signer != nil && !$0.signedByApple }.count
        let orphans = items.filter(\.orphaned).count, unsigned = items.filter { $0.signer?.hasPrefix("Not signed") == true }.count
        var issues: [String] = []
        if orphans > 0 { issues.append("\(orphans) point to programs that no longer exist (leftovers of removed apps)") }
        if unsigned > 0 { issues.append("\(unsigned) run unsigned programs") }
        return CheckResult(id: "startup", group: startup, title: t, status: issues.isEmpty ? .pass : .attention, value: "\(items.count) items",
                           detail: "\(items.count) launch agents and daemons start automatically, \(third) not from Apple."
                               + (issues.isEmpty ? "" : " " + issues.joined(separator: "; ") + ".")
                               + " Login items from System Events aren't counted here (listing them needs Automation permission; see Startup Apps).", fixes: fix)
    }

    public static func kexts(_ out: String?) -> CheckResult {
        let t = "Third-party kernel extensions"
        guard let out, out.contains("com.apple.") else { return unknown("kexts", startup, t, "kmutil showloaded gave no usable output.") }
        let k = CheckupParse.thirdPartyKexts(out)
        if k.isEmpty { return CheckResult(id: "kexts", group: startup, title: t, status: .pass, value: "None", detail: "Only Apple's kernel extensions are loaded.") }
        return CheckResult(id: "kexts", group: startup, title: t, status: .attention, value: "\(k.count) loaded",
                           detail: k.joined(separator: ", ") + ". Kernel extensions run with full kernel privileges and are a common cause of panics; Apple has deprecated them in favour of system extensions.")
    }

    public static func systemExtensions(_ out: String?) -> CheckResult {
        let t = "System extensions", fix = [CheckResult.Fix.settings(label: "Login Items & Extensions", url: SettingsPane.loginItems)]
        guard let out else { return unknown("sysext", startup, t, "systemextensionsctl could not be run.", fixes: fix) }
        let all = CheckupParse.systemExtensions(out).filter { $0.teamID != "-" && $0.teamID != "Apple" }
        if all.isEmpty { return CheckResult(id: "sysext", group: startup, title: t, status: .pass, value: "None", detail: "No third-party system extensions are installed.", fixes: fix) }
        // Ones stuck waiting for approval, or left behind by uninstalled apps, are listed as needing a look.
        let stuck = all.filter { !($0.enabled && $0.active) && !$0.state.contains("uninstall") }
        let list = all.map { "\($0.bundleID) [\($0.state)]" }.joined(separator: ", ")
        return CheckResult(id: "sysext", group: startup, title: t, status: stuck.isEmpty ? .pass : .attention, value: "\(all.count) installed",
                           detail: list + (stuck.isEmpty ? ". These run outside the kernel with limited privileges." : ". Some aren't active (waiting for approval, or left behind)."), fixes: fix)
    }
}
