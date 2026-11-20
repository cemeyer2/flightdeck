import Foundation
// Fleet, part 5: where pairing secrets live. A single JSON file, ~/Library/Application Support/Flightdeck/Fleet/
// fleet.json, mode 0600 in a 0700 folder, written atomically. Not the Keychain: FlightDeck is ad-hoc signed, so each
// update has a new code signature and macOS would ask "FlightDeck wants to use your confidential information" for
// every item, at whatever moment the background poll or the sharing server first touched it. A file only this account
// can read gives the same protection against other users; other software running as you could read either.

public struct FleetState: Codable, Sendable, Equatable {
    /// This Mac's fleet ID: random, made once, sent to Macs it pairs with (and in its Bonjour TXT record).
    public var instanceID: String
    /// Host side: Macs allowed to read this one.
    public var viewers: [FleetPeer]
    /// Viewer side: Macs this one reads.
    public var hosts: [FleetPeer]
    public init(instanceID: String = UUID().uuidString, viewers: [FleetPeer] = [], hosts: [FleetPeer] = []) {
        self.instanceID = instanceID; self.viewers = viewers; self.hosts = hosts
    }
}

public final class FleetStore: @unchecked Sendable {
    public static var defaultDirectory: URL { DailyLog.defaultDirectory.appendingPathComponent("Fleet") }
    /// nil: memory only (tests, demo mode).
    public let dir: URL?
    private let lock = NSLock()
    private var state: FleetState

    public init(dir: URL?) {
        self.dir = dir
        if let dir, let data = try? Data(contentsOf: dir.appendingPathComponent("fleet.json")),
           let s = try? JSONDecoder.fleet.decode(FleetState.self, from: data) {
            state = s
        } else {
            state = FleetState()
        }
    }

    public var snapshot: FleetState { lock.lock(); defer { lock.unlock() }; return state }
    public var instanceID: String { snapshot.instanceID }

    public func viewer(_ id: String) -> FleetPeer? { snapshot.viewers.first { $0.id == id } }
    public func host(_ id: String) -> FleetPeer? { snapshot.hosts.first { $0.id == id } }

    /// Applies `change` and saves (only if anything changed).
    public func update(_ change: (inout FleetState) -> Void) {
        lock.lock()
        var s = state
        change(&s)
        let changed = s != state
        state = s
        lock.unlock()
        if changed { save(s) }
    }

    public func addViewer(_ p: FleetPeer) { update { s in s.viewers.removeAll { $0.id == p.id }; s.viewers.append(p) } }
    public func removeViewer(_ id: String) { update { s in s.viewers.removeAll { $0.id == id } } }
    public func addHost(_ p: FleetPeer) { update { s in s.hosts.removeAll { $0.id == p.id }; s.hosts.append(p) } }
    public func removeHost(_ id: String) { update { s in s.hosts.removeAll { $0.id == id } } }

    private func save(_ s: FleetState) {
        guard let dir, let data = try? JSONEncoder.fleet.encode(s) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let url = dir.appendingPathComponent("fleet.json"), tmp = dir.appendingPathComponent(".fleet.json.tmp")
        // Created 0600 before any secret is written into it, then moved over the old file.
        fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let h = try? FileHandle(forWritingTo: tmp) else { return }
        h.write(data); try? h.close()
        _ = try? fm.replaceItemAt(url, withItemAt: tmp)
        if !fm.fileExists(atPath: url.path) { try? fm.moveItem(at: tmp, to: url) }
    }
}

extension JSONEncoder {
    /// ISO 8601 dates, sorted keys: the fleet wire format and its saved file.
    public static var fleet: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
}
extension JSONDecoder {
    public static var fleet: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
