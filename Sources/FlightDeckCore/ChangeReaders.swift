import Foundation

// The What Changed readers: one per category, each cheap and readable without root. The I/O is in `ChangeReaders.read`;
// the parsing is in small pure functions so tests can feed captured output. A full read takes well under a second on
// a typical Mac (one `launchctl print` and `print-disabled`, `kmutil showloaded`, `systemextensionsctl list`,
// `profiles`, the launchd folders, the Applications folders' Info.plists and the Homebrew folder listings). Code
// signatures are checked for launch items (as Startup Apps does) and only for apps that are new or updated.

public enum ChangeReaders {
    /// Reads every category. `previous` supplies app signatures already checked, so an unchanged app isn't checked
    /// again. Blocking; call off the main thread.
    public static func read(previous: Inventory?, now: Date = Date()) -> Inventory {
        var inv = Inventory(time: now, items: [], boot: Sysctl.timeval("kern.boottime"))
        if let os = macOS() { inv.items.append(os) } else { inv.unavailable[.macOS] = "SystemVersion.plist couldn't be read." }
        // Login items need System Events (an Automation prompt), so only launchd plists are tracked here.
        inv.items += Launchd.startupItems(includeLoginItems: false).map(launchItem)
        inv.limits.append("Login items and apps' background items (System Settings › Login Items) aren't listed: reading them needs Automation permission or root. Launch agents and daemons are.")
        if let out = Shell.run("/usr/bin/systemextensionsctl", ["list"]) { inv.items += systemExtensions(out) }
        else { inv.unavailable[.systemExtension] = "systemextensionsctl could not be run." }
        if let out = Shell.run("/usr/bin/kmutil", ["showloaded", "--list-only"], timeout: 20), out.contains("com.apple.") { inv.items += kernelExtensions(out) }
        else { inv.unavailable[.kernelExtension] = "kmutil showloaded gave no usable output." }
        inv.items += profiles(user: Shell.run("/usr/bin/profiles", ["list"]), enrollment: Shell.run("/usr/bin/profiles", ["status", "-type", "enrollment"]))
        inv.items += managedPreferences()
        inv.limits.append("Configuration profiles installed for the whole Mac can only be listed with root; FlightDeck shows your user's profiles, MDM enrollment and the managed-settings domains they create in /Library/Managed Preferences.")
        if let out = Shell.run("/bin/launchctl", ["print-disabled", "system"], timeout: 5) {
            inv.items += sharing(overrides: Launchd.parseDisabled(out), plistDisabled: sharingDefaults())
        } else { inv.unavailable[.sharing] = "launchctl print-disabled system could not be run." }
        inv.items += apps(InstalledApps.scan(), previous: previous)
        if let root = brewRoot() { inv.items += homebrew(root: root) }
        else { inv.unavailable[.homebrew] = "Homebrew isn't installed (no /opt/homebrew or /usr/local Cellar)." }
        return inv
    }

    // MARK: macOS

    static func macOS() -> InventoryItem? {
        guard let d = NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist") as? [String: Any] else { return nil }
        return macOS(d)
    }

    /// "27.2 (26B123)", plus a Rapid Security Response suffix ("(a)") when there is one.
    static func macOS(_ d: [String: Any]) -> InventoryItem? {
        guard let v = d["ProductVersion"] as? String else { return nil }
        let extra = (d["ProductVersionExtra"] as? String).map { " \($0)" } ?? ""
        let build = (d["ProductBuildVersion"] as? String).map { " (\($0))" } ?? ""
        return InventoryItem(category: .macOS, key: "macOS", name: "macOS", version: v + extra + build)
    }

    // MARK: Launch agents and daemons

    static func launchItem(_ s: StartupItem) -> InventoryItem {
        let attrs = try? FileManager.default.attributesOfItem(atPath: s.path)
        let sig: SignatureState? = s.signedByApple ? .apple : s.signer.map { $0.hasPrefix("Not signed") ? .unsigned : ($0 == "Ad-hoc signed" ? .adHoc : .developer) }
        return InventoryItem(category: .launchItem, key: s.path, name: s.label, scope: s.kind, path: s.path, program: s.program,
                             state: s.disabled ? "Disabled" : nil, signer: s.signer, teamID: teamID(s.signer), signature: sig,
                             runsAtLoad: s.runAtLoad || s.keepAlive, modified: attrs?[.modificationDate] as? Date)
    }

    /// The team id in a Developer ID signer string ("Developer ID Application: Example Corp (ABCDE12345)").
    static func teamID(_ signer: String?) -> String? {
        guard let s = signer, s.hasSuffix(")"), let open = s.lastIndex(of: "(") else { return nil }
        let t = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
        return t.count == 10 && t.allSatisfy { $0.isUppercase || $0.isNumber } ? t : nil
    }

    // MARK: System and kernel extensions

    /// Third-party system extensions from `systemextensionsctl list`, with the version from the "(version)" column.
    static func systemExtensions(_ out: String) -> [InventoryItem] {
        var versions: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let c = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard c.count >= 4 else { continue }
            let parts = c[3].split(separator: " ", maxSplits: 1)
            if parts.count == 2 { versions[String(parts[0])] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
        }
        return CheckupParse.systemExtensions(out).filter { $0.teamID != "-" && $0.teamID != "Apple" }.map { x in
            InventoryItem(category: .systemExtension, key: x.bundleID, name: x.name, version: versions[x.bundleID],
                          state: x.state, teamID: x.teamID, bundleID: x.bundleID)
        }
    }

    /// Loaded third-party kernel extensions from `kmutil showloaded --list-only`.
    static func kernelExtensions(_ out: String) -> [InventoryItem] {
        CheckupParse.thirdPartyKexts(out).map { s in
            let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
            let v = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()")) : nil
            return InventoryItem(category: .kernelExtension, key: parts[0], name: parts[0], version: v, state: "Loaded", bundleID: parts[0])
        }
    }

    // MARK: Profiles

    /// The user's profiles from `profiles list` ("<user>[1] attribute: profileIdentifier: com.example.wifi") and the
    /// enrollment state from `profiles status -type enrollment` ("MDM enrollment: Yes (User Approved)").
    static func profiles(user: String?, enrollment: String?) -> [InventoryItem] {
        var out: [InventoryItem] = []
        for line in (user ?? "").split(separator: "\n") {
            guard let r = line.range(of: "profileIdentifier:") else { continue }
            let id = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            let owner = line.split(separator: "[").first.map(String.init) ?? ""
            guard !id.isEmpty else { continue }
            out.append(InventoryItem(category: .profile, key: "profile:" + id, name: id, scope: owner == "_computerlevel" ? "This Mac" : "User \(owner)"))
        }
        for line in (enrollment ?? "").split(separator: "\n") {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, kv[0].hasPrefix("Enrolled via DEP") || kv[0].hasPrefix("MDM enrollment") else { continue }
            out.append(InventoryItem(category: .profile, key: "enrollment:" + kv[0], name: kv[0], scope: "Enrollment", state: kv[1]))
        }
        return out
    }

    /// Settings domains forced by profiles: the plists in /Library/Managed Preferences (and its per-user folder).
    static func managedPreferences(root: String = "/Library/Managed Preferences") -> [InventoryItem] {
        let fm = FileManager.default
        var out: [InventoryItem] = []
        for dir in [root, root + "/" + NSUserName()] {
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".plist") {
                let path = dir + "/" + f
                let domain = (f as NSString).deletingPathExtension
                out.append(InventoryItem(category: .profile, key: "managed:" + path, name: domain, scope: dir == root ? "Managed setting (this Mac)" : "Managed setting (user)",
                                         path: path, modified: (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date))
            }
        }
        return out
    }

    // MARK: Sharing

    /// Sharing services and the launchd job behind each. A job is on when launchd's override database says enabled,
    /// or, without an override, when its plist isn't Disabled (all of these ship disabled).
    public static let sharingServices: [(label: String, name: String, plist: String)] = [
        ("com.openssh.sshd", "Remote Login (SSH)", "ssh.plist"),
        ("com.apple.screensharing", "Screen Sharing", "com.apple.screensharing.plist"),
        ("com.apple.smbd", "File Sharing (SMB)", "com.apple.smbd.plist"),
        ("com.apple.AEServer", "Remote Apple Events", "com.apple.AEServer.plist"),
        ("com.apple.NetworkSharing", "Internet Sharing", "com.apple.NetworkSharing.plist"),
    ]

    static func sharingDefaults() -> [String: Bool] {
        var d: [String: Bool] = [:]
        for s in sharingServices {
            let p = NSDictionary(contentsOfFile: "/System/Library/LaunchDaemons/" + s.plist) as? [String: Any]
            d[s.label] = p?["Disabled"] as? Bool ?? true
        }
        return d
    }

    static func sharing(overrides: [String: Bool], plistDisabled: [String: Bool]) -> [InventoryItem] {
        sharingServices.map { s in
            let disabled = overrides[s.label] ?? plistDisabled[s.label] ?? true
            return InventoryItem(category: .sharing, key: s.label, name: s.name, scope: "launchd job " + s.label, state: disabled ? "Off" : "On")
        }
    }

    // MARK: Apps

    /// Apps outside /System (those change with macOS itself). An app whose path, version and modification time match
    /// the previous inventory keeps its saved signature; others are checked now (~ms each).
    static func apps(_ list: [InstalledApp], previous: Inventory?) -> [InventoryItem] {
        let old = Dictionary((previous?.items(.app) ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let firstRun = previous == nil
        return list.filter { !$0.isSystem }.map { a in
            var item = InventoryItem(category: .app, key: a.path, name: a.name, version: a.version.isEmpty ? nil : a.version, path: a.path,
                                     bundleID: a.bundleID.isEmpty ? nil : a.bundleID, modified: a.modified)
            if let o = old[a.path], o.version == item.version {
                item.signer = o.signer; item.teamID = o.teamID; item.signature = o.signature
            } else if !firstRun {
                // The baseline skips signatures (hundreds of apps); they're checked when an app is added or updated.
                let s = ProcessInspector.signature(a.path)
                item.signature = SignatureState.of(s); item.signer = s?.summary; item.teamID = s?.teamID
            }
            return item
        }
    }

    // MARK: Homebrew

    static func brewRoot() -> String? {
        ["/opt/homebrew", "/usr/local"].first { FileManager.default.fileExists(atPath: $0 + "/Cellar") || FileManager.default.fileExists(atPath: $0 + "/Caskroom") }
    }

    /// Formulae (Cellar/<name>/<version>) and casks (Caskroom/<name>/<version>): the newest version folder of each.
    /// Only folder listings; brew itself is never run.
    static func homebrew(root: String) -> [InventoryItem] {
        let fm = FileManager.default
        var out: [InventoryItem] = []
        for (dir, scope) in [("Cellar", "formula"), ("Caskroom", "cask")] {
            for name in (try? fm.contentsOfDirectory(atPath: "\(root)/\(dir)")) ?? [] where !name.hasPrefix(".") {
                let base = "\(root)/\(dir)/\(name)"
                let versions = ((try? fm.contentsOfDirectory(atPath: base)) ?? []).filter { !$0.hasPrefix(".") }
                let dated = versions.map { v in (v, (try? fm.attributesOfItem(atPath: base + "/" + v))?[.modificationDate] as? Date) }
                guard let newest = dated.max(by: { ($0.1 ?? .distantPast) < ($1.1 ?? .distantPast) }) else { continue }
                out.append(InventoryItem(category: .homebrew, key: "\(scope):\(name)", name: name, version: newest.0, scope: scope,
                                         path: base + "/" + newest.0, modified: newest.1))
            }
        }
        return out
    }
}
