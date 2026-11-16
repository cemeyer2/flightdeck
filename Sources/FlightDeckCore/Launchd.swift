import Foundation

// The Startup Items and Services tools: what launchd has loaded for this user, and what is configured to start
// automatically (LaunchAgents/LaunchDaemons plists and login items), with code-signature checks to spot orphans and
// unsigned programs. Loaded on demand from the UI, never per tick.
/// One job from `launchctl list`. `pid` is nil when the job is loaded but not running; `lastExit` is its last exit
/// status (negative values are the signal that killed it).
public struct ServiceItem: Identifiable, Hashable, Sendable {
    public var id: String { label }
    public var label: String
    public var pid: Int32?
    public var lastExit: Int?
    public var domain: String     // "user (gui)" or "system"
    public var isRunning: Bool { pid != nil }
}

/// One thing configured to start automatically. `loaded` means launchd currently lists the label; `vendor` is guessed
/// from the reverse-DNS label ("com.google.keystone" -> "Google").
public struct StartupItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var label: String
    public var path: String
    public var program: String
    public var kind: String        // Launch Agent (User), Launch Agent (All Users), Launch Daemon, Login Item
    public var runAtLoad: Bool
    public var keepAlive: Bool
    public var disabled: Bool
    public var loaded: Bool
    public var vendor: String
    /// nil = can't tell (e.g. a program inside an app bundle referenced by BundleProgram).
    public var programExists: Bool? = nil
    /// Code-signature summary of the program ("Signed by Apple", "Signed: Developer ID Application: …", "Not signed…").
    public var signer: String? = nil
    public var signedByApple = false
    /// The plist points at a program file that no longer exists (typically left behind by an uninstalled app).
    public var orphaned: Bool { programExists == false }
}

public enum Launchd {
    /// Parses the tab-separated `launchctl list` table (PID, Status, Label; "-" for no PID / status). Run as a normal user
    /// this lists only the user's own gui/<uid> domain, not system daemons, so `domain` is always the user domain.
    public static func services() -> [ServiceItem] {
        guard let out = Shell.run("/bin/launchctl", ["list"]) else { return [] }
        return out.split(separator: "\n").dropFirst().compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard c.count >= 3 else { return nil }
            return ServiceItem(label: String(c[2]), pid: Int32(c[0]), lastExit: Int(c[1]), domain: "user (gui/\(getuid()))")
        }.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    /// Reads the plists in the three standard launchd folders plus login items, then checks each absolute program path
    /// for existence and signature. Blocking (signature checks, launchctl, osascript); call off the main thread.
    /// `includeLoginItems: false` skips the System Events query, which can raise an Automation permission prompt
    /// (Checkup uses this so opening it never prompts).
    public static func startupItems(includeLoginItems: Bool = true) -> [StartupItem] {
        // `launchctl list` as a normal user only covers this user's gui domain; Launch Daemons live in the system domain,
        // which `launchctl print system` lists (label in the last column) without root.
        let loaded = Set(services().map(\.label)).union(systemDomainLabels())
        let overrides = disabledOverrides("gui/\(getuid())").merging(disabledOverrides("system")) { a, _ in a }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs: [(String, String)] = [
            ("\(home)/Library/LaunchAgents", "Launch Agent (User)"),
            ("/Library/LaunchAgents", "Launch Agent (All Users)"),
            ("/Library/LaunchDaemons", "Launch Daemon"),
        ]
        var out: [StartupItem] = []
        for (dir, kind) in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".plist") {
                let path = "\(dir)/\(f)"
                guard let d = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
                let label = d["Label"] as? String ?? (f as NSString).deletingPathExtension
                // launchd runs `Program` if present, otherwise ProgramArguments[0]. BundleProgram (SMAppService-registered
                // items) is
                // relative to the owning app bundle, which isn't known from the plist, so it is shown but not checked.
                let program = (d["Program"] as? String) ?? ((d["ProgramArguments"] as? [String])?.first
                    ?? (d["BundleProgram"] as? String).map { "(in app bundle) " + $0 } ?? "")
                // KeepAlive may be a Bool or a dictionary of conditions; a dictionary means "keep alive under some conditions".
                let keep: Bool = (d["KeepAlive"] as? Bool) ?? (d["KeepAlive"] is [String: Any])
                out.append(StartupItem(label: label, path: path, program: program, kind: kind,
                                       runAtLoad: d["RunAtLoad"] as? Bool ?? false, keepAlive: keep,
                                       // Only the plist's own Disabled key is read; `launchctl disable` overrides live in
                                       // launchd's database and aren't seen.
                                       // launchd's own override database wins over the plist's Disabled key
                                       disabled: overrides[label] ?? (d["Disabled"] as? Bool ?? false),
                                       loaded: loaded.contains(label), vendor: vendor(label)))
            }
        }
        if includeLoginItems { out.append(contentsOf: loginItems()) }
        // Who signed what starts automatically, and which items point at programs that no longer exist
        // A bare command name (no leading "/") is resolved by launchd at run time, so existence can't be judged here and
        // programExists stays nil. An existing file without a readable code object is reported as not signed.
        for i in out.indices where !out[i].program.isEmpty && out[i].program.hasPrefix("/") {
            out[i].programExists = FileManager.default.fileExists(atPath: out[i].program)
            if out[i].programExists == true, let sig = ProcessInspector.signature(out[i].program) {
                out[i].signer = sig.summary; out[i].signedByApple = sig.isApple
            } else if out[i].programExists == true {
                out[i].signer = "Not signed"
            }
        }
        return out.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    /// The second component of a reverse-DNS label, capitalised; the whole label if it has no dots.
    static func systemDomainLabels() -> Set<String> {
        guard let out = Shell.run("/bin/launchctl", ["print", "system"], timeout: 5) else { return [] }
        var inServices = false, labels = Set<String>()
        for line in out.split(separator: "\n") {
            if line.hasPrefix("\tservices = {") { inServices = true; continue }
            if inServices && line.hasPrefix("\t}") { break }
            if inServices, let label = line.split(separator: "\t").last?.trimmingCharacters(in: .whitespaces), !label.isEmpty { labels.insert(label) }
        }
        return labels
    }

    static func vendor(_ label: String) -> String {
        let parts = label.split(separator: ".")
        return parts.count >= 2 ? String(parts[1]).capitalized : label
    }

    /// Classic login items via System Events AppleScript (the only non-private way to list them). The first call triggers
    /// macOS's Automation permission prompt; if denied, osascript prints nothing and the list is empty. The output is a
    /// ", "-separated list of paths. Items registered as background items through SMAppService are not included.
    /// `launchctl print-disabled <domain>`: services launchd itself has marked enabled/disabled (e.g. via
    /// `launchctl disable` or System Settings), which overrides the plist's own Disabled key.
    static func disabledOverrides(_ domain: String) -> [String: Bool] {
        guard let out = Shell.run("/bin/launchctl", ["print-disabled", domain], timeout: 5) else { return [:] }
        return parseDisabled(out)
    }

    static func parseDisabled(_ out: String) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.components(separatedBy: "\" => ")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            map[label] = parts[1].trimmingCharacters(in: .whitespaces).hasPrefix("disabled")
        }
        return map
    }

    static func loginItems() -> [StartupItem] {
        // One path per line: AppleScript's default list output separates with ", ", which breaks paths containing ", ".
        let script = """
        tell application "System Events" to set ps to the path of every login item
        set AppleScript's text item delimiters to linefeed
        return ps as text
        """
        guard let out = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 5) else { return [] }
        return out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").filter { !$0.isEmpty }.map {
            StartupItem(label: (($0 as NSString).lastPathComponent as NSString).deletingPathExtension, path: $0, program: $0,
                        kind: "Login Item", runAtLoad: true, keepAlive: false, disabled: false, loaded: true, vendor: "")
        }
    }
}
