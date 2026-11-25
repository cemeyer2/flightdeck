import Foundation

/// The helper's own settings. Root-owned on disk so a program running as the user can't switch agent access to
/// process contents on by itself (user defaults would let it).
public protocol HelperSettingsStoring: AnyObject {
    var agentContents: Bool { get }
    /// Throws when the setting couldn't be saved; the stored value is then unchanged.
    func setAgentContents(_ on: Bool) throws
    func removeAll()
}

/// `{"agentContents": false}` in a root-owned folder, replaced atomically with mode 0600. The only file the helper
/// writes (with its temporary copy while saving).
public final class FileHelperSettingsStore: HelperSettingsStoring {
    private struct Contents: Codable { var agentContents: Bool }
    let url: URL
    /// Sets a file's mode to 0600; replaceable so a test can make it fail.
    private let ownerOnly: (String) throws -> Void

    public convenience init(url: URL = URL(fileURLWithPath: "/Library/Application Support/FlightDeck Helper/settings.json")) {
        self.init(url: url, ownerOnly: { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: $0) })
    }

    init(url: URL, ownerOnly: @escaping (String) throws -> Void) {
        self.url = url; self.ownerOnly = ownerOnly
    }

    public var agentContents: Bool {
        guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Contents.self, from: d) else { return false }
        return c.agentContents
    }

    /// Written to a temporary file beside the real one, given its mode, then renamed over it: any failure leaves the
    /// stored value as it was, and the new value never lands without mode 0600.
    public func setAgentContents(_ on: Bool) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".settings-\(UUID().uuidString).tmp")
        do {
            try JSONEncoder().encode(Contents(agentContents: on)).write(to: tmp, options: .withoutOverwriting)
            try ownerOnly(tmp.path)
            guard rename(tmp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
