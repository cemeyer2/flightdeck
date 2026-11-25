import Foundation
// Chrome tabs: the latest validated table from each extension connection (one per Chrome profile), held in memory only.
// The socket listener writes from its own queue and the Engine's sampler queue reads, so every access takes the lock.
// Keys carry the browser process the app derived itself (pid plus start time), never anything the extension said.

public final class ChromeTabStore: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public var browser: ProcessIdentity
        public var connection: UInt64
        public init(browser: ProcessIdentity, connection: UInt64) { self.browser = browser; self.connection = connection }
    }
    public struct Hello: Sendable, Equatable {
        public var protocolVersion: Int
        public var extensionVersion: String
        public init(protocolVersion: Int, extensionVersion: String) { self.protocolVersion = protocolVersion; self.extensionVersion = extensionVersion }
    }

    private let lock = NSLock()
    private var tablesByKey: [Key: ChromeTabTable] = [:]
    private var hellosByKey: [Key: Hello] = [:]

    public init() {}

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    /// A hello with another protocol also drops that connection's table: its tables are ignored from now on.
    public func setHello(_ h: Hello, for k: Key) {
        locked {
            hellosByKey[k] = h
            if h.protocolVersion != ChromeTabsConstants.protocolVersion { tablesByKey[k] = nil }
        }
    }

    /// Ignored unless that connection said hello with the current protocol.
    public func setTable(_ t: ChromeTabTable, for k: Key) {
        locked {
            guard hellosByKey[k]?.protocolVersion == ChromeTabsConstants.protocolVersion else { return }
            tablesByKey[k] = t
        }
    }

    /// A message from this connection failed validation: its previous table goes too, so no stale labels remain.
    public func invalidate(_ k: Key) { locked { tablesByKey[k] = nil } }

    /// The connection closed. Other profiles' tables stay.
    public func remove(_ k: Key) { locked { tablesByKey[k] = nil; hellosByKey[k] = nil } }

    public func removeAll() { locked { tablesByKey.removeAll(); hellosByKey.removeAll() } }

    /// Drops the tables of browser processes that are no longer running (or whose pid now belongs to a new process).
    /// Hellos stay until their connection closes: the extension says hello only on connect, so dropping one after a
    /// sample that happened to miss the browser would make that connection's later tables be ignored for good.
    public func prune(liveBrowsers: Set<ProcessIdentity>) {
        locked { tablesByKey = tablesByKey.filter { liveBrowsers.contains($0.key.browser) } }
    }

    public func tables() -> [Key: ChromeTabTable] { locked { tablesByKey } }
    public func hellos() -> [Key: Hello] { locked { hellosByKey } }
    /// Nothing connected at all. The Engine checks this first, so with the feature off sampling does no extra work.
    public var isEmpty: Bool { locked { tablesByKey.isEmpty && hellosByKey.isEmpty } }
}
