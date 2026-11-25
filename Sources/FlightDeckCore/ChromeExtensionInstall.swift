import Foundation
// Chrome tabs: what FlightDeck installs, and removes again when the feature is turned off.
// - The native-messaging host manifest in Chrome's NativeMessagingHosts folder, naming the app binary as the host and
//   our extension origin(s) as the only callers. Rewritten at launch when the app has moved.
// - A stable copy of the bundled extension outside the .app (Application Support/Flightdeck/ChromeExtension), which the
//   user loads with "Load unpacked", so moving or updating the app doesn't pull the folder out from under Chrome.
// FlightDeck can't install or remove the extension itself; Settings walks the user through that.

public enum ChromeExtensionInstall {
    public static func nativeHostsDir(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
    }

    /// Spelled like the app's other folders in Application Support (see BlackBox.defaultDirectory).
    public static func stableCopyDir(appSupport: URL) -> URL {
        appSupport.appendingPathComponent("Flightdeck/ChromeExtension", isDirectory: true)
    }

    static var manifestName: String { ChromeTabsConstants.hostName + ".json" }

    public static func hostManifest(executablePath: String, origins: [String] = ChromeTabsConstants.allowedOrigins) -> Data {
        let j: JSON = ["name": .string(ChromeTabsConstants.hostName), "description": "FlightDeck Chrome tabs",
                       "path": .string(executablePath), "type": "stdio", "allowed_origins": .strings(origins)]
        return j.data
    }

    /// Writes the manifest atomically (a temporary file in the same folder, then a rename), mode 0644.
    public static func writeHostManifest(dir: URL, executablePath: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(manifestName).\(UUID().uuidString)")
        do {
            try hostManifest(executablePath: executablePath).write(to: tmp)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp.path)
            guard rename(tmp.path, dir.appendingPathComponent(manifestName).path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    public static func removeHostManifest(dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(manifestName))
    }

    public static func readHostManifest(dir: URL) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(manifestName)) }

    /// True when the manifest is missing, unreadable, or names another binary or other origins (e.g. the app moved).
    public static func needsRewrite(existing: Data?, executablePath: String) -> Bool {
        guard let existing, let j = try? JSON.parse(existing) else { return true }
        return j["path"]?.string != executablePath
            || j["allowed_origins"]?.array?.compactMap(\.string) != ChromeTabsConstants.allowedOrigins
            || j["name"]?.string != ChromeTabsConstants.hostName
    }

    /// Compared as `ReleaseVersion`s, so the extension and update checks order versions the same way: "1.0.10" is newer
    /// than "1.0.9" and missing parts count as 0. A version that isn't dotted digits is never newer.
    public static func isVersion(_ a: String, newerThan b: String) -> Bool {
        guard let x = ReleaseVersion(a), let y = ReleaseVersion(b) else { return false }
        return x > y
    }

    /// The `version` in an extension folder's manifest.json, nil when there's no readable manifest.
    public static func manifestVersion(at extDir: URL) -> String? {
        guard let d = try? Data(contentsOf: extDir.appendingPathComponent("manifest.json")), let j = try? JSON.parse(d) else { return nil }
        return j["version"]?.string
    }

    /// Copies the bundled extension into place: first to a sibling temporary folder, then swapped in, so Chrome never
    /// sees a half-copied folder.
    public static func installStableCopy(from bundled: URL, to stable: URL) throws {
        let fm = FileManager.default
        let parent = stable.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let tmp = parent.appendingPathComponent(".\(stable.lastPathComponent).\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.copyItem(at: bundled, to: tmp)
            if fm.fileExists(atPath: stable.path) {
                _ = try fm.replaceItemAt(stable, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: stable)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    public static func removeStableCopy(_ stable: URL) { try? FileManager.default.removeItem(at: stable) }
}
