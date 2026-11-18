import Foundation

// Homebrew services for the Developer destination: `brew services list --json` and start/stop/restart. brew is a
// Ruby program that takes ~1-2 s to start, so the UI only lists services when the view appears, on Refresh and after
// an action, never on the 5-second container timer.

/// One service from `brew services list --json`.
public struct BrewService: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    /// "started", "stopped", "none" (not loaded), "error", "scheduled", "unknown" or "other", as brew reports it.
    public var status: String
    /// The user it runs as ("root" for a system daemon started with sudo); nil when not loaded.
    public var user: String?
    /// The launchd plist brew uses for it.
    public var plist: String?
    /// The last exit code launchd recorded, when brew reports one.
    public var exitCode: Int?
    public var isRunning: Bool { status == "started" }
    public init(name: String, status: String, user: String?, plist: String?, exitCode: Int?) {
        self.name = name; self.status = status; self.user = user; self.plist = plist; self.exitCode = exitCode
    }
}

public enum BrewStatus: Sendable {
    case noBrew
    case failed(reason: String)
    case ok([BrewService])
}

public enum Brew {
    /// Homebrew's own locations (Apple silicon, then Intel). Only the file system is checked.
    public static func locate() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Environment for every brew call: no auto-update (it could otherwise fetch from GitHub), no analytics, no hints.
    static let env = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1",
                      "HOMEBREW_NO_INSTALL_CLEANUP": "1"]

    /// Lists services. Blocking (~1-2 s); call off the main thread.
    public static func services() -> BrewStatus {
        guard let brew = locate() else { return .noBrew }
        guard let r = DevShell.run(brew, ["services", "list", "--json"], timeout: 30, env: env) else { return .failed(reason: "brew couldn't be started") }
        guard r.ok else { return .failed(reason: r.reason) }
        guard let list = parse(r.stdout) else { return .failed(reason: "brew printed something other than the expected JSON") }
        return .ok(list)
    }

    public enum Action: String, Sendable, CaseIterable { case start, stop, restart }

    /// `brew services start|stop|restart <name>`; nil on success, else brew's message. Only user-level services can be
    /// managed this way: a service loaded as root needs `sudo brew services`, which FlightDeck doesn't do.
    public static func perform(_ a: Action, service: String) -> String? {
        guard let brew = locate() else { return "Homebrew is no longer installed" }
        // Service names are formula names; refuse anything that could be read as an option.
        guard !service.hasPrefix("-"), !service.isEmpty else { return "invalid service name" }
        guard let r = DevShell.run(brew, ["services", a.rawValue, service], timeout: 60, env: env) else { return "brew couldn't be started" }
        return r.ok ? nil : r.reason
    }

    /// Parses the JSON array brew prints. `user`, `file` and `exit_code` may be null; an empty list prints `[]`.
    /// nil if the text isn't a JSON array (an error message, or an old brew without --json).
    static func parse(_ out: String) -> [BrewService]? {
        guard let start = out.firstIndex(of: "["),
              let arr = (try? JSONSerialization.jsonObject(with: Data(out[start...].utf8))) as? [[String: Any]] else { return nil }
        return arr.compactMap { o in
            guard let name = o["name"] as? String else { return nil }
            return BrewService(name: name, status: o["status"] as? String ?? "unknown", user: o["user"] as? String,
                               plist: o["file"] as? String, exitCode: (o["exit_code"] as? NSNumber)?.intValue)
        }
    }
}
