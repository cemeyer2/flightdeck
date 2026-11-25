import Foundation

/// The helper's own settings. Root-owned on disk so a program running as the user can't switch agent access to
/// process contents on by itself (user defaults would let it).
public protocol HelperSettingsStoring: AnyObject {
    var agentContents: Bool { get set }
    func removeAll()
}

/// `{"agentContents": false}` in a root-owned folder, written atomically with mode 0600. The only file the helper
/// writes.
public final class FileHelperSettingsStore: HelperSettingsStoring {
    private struct Contents: Codable { var agentContents: Bool }
    let url: URL

    public init(url: URL = URL(fileURLWithPath: "/Library/Application Support/FlightDeck Helper/settings.json")) {
        self.url = url
    }

    public var agentContents: Bool {
        get {
            guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Contents.self, from: d) else { return false }
            return c.agentContents
        }
        set {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            guard let d = try? JSONEncoder().encode(Contents(agentContents: newValue)) else { return }
            do {
                try d.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {}
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
