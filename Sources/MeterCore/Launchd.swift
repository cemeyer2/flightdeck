import Foundation

public struct ServiceItem: Identifiable, Hashable, Sendable {
    public var id: String { label }
    public var label: String
    public var pid: Int32?
    public var lastExit: Int?
    public var domain: String     // "user (gui)" or "system"
    public var isRunning: Bool { pid != nil }
}

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
}

public enum Launchd {
    public static func services() -> [ServiceItem] {
        guard let out = Shell.run("/bin/launchctl", ["list"]) else { return [] }
        return out.split(separator: "\n").dropFirst().compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard c.count >= 3 else { return nil }
            return ServiceItem(label: String(c[2]), pid: Int32(c[0]), lastExit: Int(c[1]), domain: "user (gui/\(getuid()))")
        }.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    public static func startupItems() -> [StartupItem] {
        let loaded = Set(services().map(\.label))
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
                let program = (d["Program"] as? String) ?? ((d["ProgramArguments"] as? [String])?.first ?? "")
                let keep: Bool = (d["KeepAlive"] as? Bool) ?? (d["KeepAlive"] is [String: Any])
                out.append(StartupItem(label: label, path: path, program: program, kind: kind,
                                       runAtLoad: d["RunAtLoad"] as? Bool ?? false, keepAlive: keep,
                                       disabled: d["Disabled"] as? Bool ?? false,
                                       loaded: loaded.contains(label), vendor: vendor(label)))
            }
        }
        out.append(contentsOf: loginItems())
        return out.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    static func vendor(_ label: String) -> String {
        let parts = label.split(separator: ".")
        return parts.count >= 2 ? String(parts[1]).capitalized : label
    }

    static func loginItems() -> [StartupItem] {
        let script = "tell application \"System Events\" to get the path of every login item"
        guard let out = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 5) else { return [] }
        return out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ", ").filter { !$0.isEmpty }.map {
            StartupItem(label: (($0 as NSString).lastPathComponent as NSString).deletingPathExtension, path: $0, program: $0,
                        kind: "Login Item", runAtLoad: true, keepAlive: false, disabled: false, loaded: true, vendor: "")
        }
    }
}
