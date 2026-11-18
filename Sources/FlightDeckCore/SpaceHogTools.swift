import Foundation

// The official developer tools the space-hog analysis asks: simctl (simulators and their runtimes) and Homebrew.
// Neither is run through a shim that could pop up a dialog: `/usr/bin/xcrun` offers to install the Command Line Tools
// when there are none, so simctl is run from the active developer directory directly, and only if it's there.

/// A simulator device from `simctl list -j devices`.
public struct SimDevice: Sendable, Hashable {
    public var udid: String, name: String, runtime: String, state: String
    /// False when its runtime is no longer installed: it can't boot, and `simctl delete unavailable` removes it.
    public var isAvailable: Bool
    public var availabilityError: String?
}

/// A simulator runtime from `simctl runtime list -j`.
public struct SimRuntime: Sendable, Hashable {
    public var identifier: String, version: String?, platform: String?, state: String?
    /// As simctl reports it; nil when it doesn't.
    public var sizeBytes: UInt64?
}

public enum SimctlParse {
    /// `simctl list -j devices`: {"devices": {"<runtime id>": [device, ...]}}. Devices missing a udid are skipped.
    public static func devices(_ data: Data) -> [SimDevice]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let byRuntime = root["devices"] as? [String: Any] else { return nil }
        return byRuntime.sorted { $0.key < $1.key }.flatMap { runtime, list -> [SimDevice] in
            (list as? [[String: Any]] ?? []).compactMap { d in
                guard let udid = d["udid"] as? String else { return nil }
                return SimDevice(udid: udid, name: d["name"] as? String ?? udid, runtime: runtime, state: d["state"] as? String ?? "",
                                 isAvailable: d["isAvailable"] as? Bool ?? true, availabilityError: d["availabilityError"] as? String)
            }
        }
    }

    /// `simctl runtime list -j`: {"<uuid>": {runtimeIdentifier, version, platformIdentifier, state, sizeBytes, ...}}.
    /// An empty object (no downloadable runtimes installed) is a valid empty list.
    public static func runtimes(_ data: Data) -> [SimRuntime]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return root.sorted { $0.key < $1.key }.compactMap { key, value in
            guard let r = value as? [String: Any] else { return nil }
            let size = (r["sizeBytes"] as? NSNumber).flatMap { $0.int64Value > 0 ? $0.uint64Value : nil }
            return SimRuntime(identifier: r["runtimeIdentifier"] as? String ?? key, version: r["version"] as? String,
                              platform: r["platformIdentifier"] as? String, state: r["state"] as? String, sizeBytes: size)
        }
    }
}

public enum BrewParse {
    /// The paths `brew cleanup -n` would remove ("Would remove: /path (12 files, 4.5MB)").
    public static func dryRunPaths(_ out: String) -> [String] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("Would remove: ") else { return nil }
            var p = String(line.dropFirst("Would remove: ".count))
            if let r = p.range(of: " (", options: .backwards) { p = String(p[..<r.lowerBound]) }
            return p
        }
    }
    /// brew's own estimate, e.g. "4.5MB", from "This operation would free approximately 4.5MB of disk space."
    public static func dryRunEstimate(_ out: String) -> String? {
        guard let r = out.range(of: "would free approximately ") else { return nil }
        let rest = out[r.upperBound...]
        return rest.range(of: " of disk space").map { String(rest[..<$0.lowerBound]) }
    }
}

public enum DevTools {
    /// simctl inside the active developer directory, if Xcode (not just the Command Line Tools) is selected.
    public static func simctlPath() -> String? {
        guard let dev = Shell.run("/usr/bin/xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines), !dev.isEmpty else { return nil }
        let p = dev + "/usr/bin/simctl"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// Homebrew at its standard prefix (Apple silicon, then Intel). A GUI app's PATH doesn't include either.
    public static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Homebrew's environment: no auto-update, no analytics, no hints, so a dry run only reads.
    static let brewEnv = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1",
                          "HOMEBREW_NO_INSTALL_CLEANUP": "1"]

    /// `brew --cache`: where this Homebrew keeps its downloads (HOMEBREW_CACHE can move it).
    public static func brewCache(_ brew: String) -> String? {
        run(brew, ["--cache"], env: brewEnv, timeout: 20)?.output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Runs a tool with stdout and stderr merged, returning both the text and the exit status (nil if it couldn't
    /// start). `env` is added to this process's environment.
    public static func run(_ path: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval) -> (output: String, status: Int32)? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return nil }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // to EOF first, so a full pipe can't deadlock
        p.waitUntilExit(); timer.cancel()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
