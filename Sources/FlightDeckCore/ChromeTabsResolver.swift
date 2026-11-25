import Foundation
// Chrome tabs: which tabs each Chrome renderer process hosts. The extension reports every frame's Chrome process id,
// which equals the renderer's `--renderer-client-id=N` argument. Client ids are only unique within one browser
// process, and Electron apps use the same flag, so a renderer is matched only under the browser process that its
// table came from (same pid and start time) and only when it is that browser's direct child.
//
// Nothing here is Codable: attributions are published beside each sample and read at render or response time, never
// copied into ProcessSample, Snapshot, Finding or Incident.

/// What a renderer's command line says about it.
public struct ChromeRendererArgs: Sendable, Equatable {
    public var clientID: Int
    /// `--extension-process`: the renderer runs extensions rather than web pages.
    public var isExtension: Bool
    public init(clientID: Int, isExtension: Bool) { self.clientID = clientID; self.isExtension = isExtension }

    /// Needs `--type=renderer` and `--renderer-client-id=N`. Helper names vary ("(Renderer)", "(Aperitif Renderer)"),
    /// so only the arguments count.
    public static func parse(_ argv: [String]) -> ChromeRendererArgs? {
        guard argv.contains("--type=renderer") else { return nil }
        let prefix = "--renderer-client-id="
        guard let arg = argv.first(where: { $0.hasPrefix(prefix) }), let id = Int(arg.dropFirst(prefix.count)) else { return nil }
        return ChromeRendererArgs(clientID: id, isExtension: argv.contains("--extension-process"))
    }
}

/// One tab (or one tab's out-of-process frame) in a renderer. `host` and `title` are already derived and sanitised;
/// `url` is the raw tab address, shown only in the inspector and never in MCP or Copy Summary.
public struct ChromeTabEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case tab
        /// A subframe from another site, e.g. an ad, inside a tab whose page runs elsewhere.
        case frame(inTabHost: String)
    }
    public var kind: Kind
    public var host: String
    public var title: String
    public var url: String
    public var active: Bool
    public var audible: Bool
    public var lastAccessed: Double
    public init(kind: Kind, host: String, title: String, url: String, active: Bool, audible: Bool, lastAccessed: Double) {
        self.kind = kind; self.host = host; self.title = title; self.url = url; self.active = active; self.audible = audible
        self.lastAccessed = lastAccessed
    }
}

public struct ChromeTabAttribution: Sendable, Hashable {
    /// Tabs first (the active one, then most recently used), then frames in the same order.
    public var entries: [ChromeTabEntry]
    /// An extension renderer with no tabs: shown as "Chrome extension process".
    public var isExtensionProcess: Bool
    public init(entries: [ChromeTabEntry], isExtensionProcess: Bool) { self.entries = entries; self.isExtensionProcess = isExtensionProcess }
    public var tabCount: Int { entries.filter { $0.kind == .tab }.count }
}

/// Runs on the Engine's sampler queue only (not thread-safe).
public final class ChromeTabsResolver: @unchecked Sendable {
    private let arguments: (Int32) -> [String]?
    /// Parsed renderer arguments per process (nil: read, but not a renderer). A process's arguments don't change, so
    /// each is read once; pruned to live processes on every call.
    private var cache: [ProcessIdentity: ChromeRendererArgs?] = [:]

    /// `arguments` returns a process's argv, or nil when it can't be read (e.g. it just exited).
    public init(arguments: @escaping (Int32) -> [String]?) { self.arguments = arguments }
    public convenience init() { self.init(arguments: { ProcessInspector.argsAndEnv($0).0.value }) }

    public var cachedIdentityCount: Int { cache.count }

    public func resolve(processes: [ProcessSample], tables: [ChromeTabStore.Key: ChromeTabTable]) -> [ProcessIdentity: ChromeTabAttribution] {
        guard !tables.isEmpty else { cache.removeAll(); return [:] }
        let live = Set(processes.map(\.identity))
        cache = cache.filter { live.contains($0.key) }

        // Tables per browser, skipping browsers that are no longer running (pid and start time must both match).
        var byBrowser: [ProcessIdentity: [(UInt64, ChromeTabTable)]] = [:]
        for (k, t) in tables where live.contains(k.browser) { byBrowser[k.browser, default: []].append((k.connection, t)) }
        guard !byBrowser.isEmpty else { return [:] }
        let childrenOf = Dictionary(grouping: processes.filter { p in byBrowser.keys.contains { $0.pid == p.ppid } }, by: \.ppid)

        struct TabRef: Hashable { var connection: UInt64; var tabId: Int }
        var out: [ProcessIdentity: ChromeTabAttribution] = [:]
        for (browser, browserTables) in byBrowser {
            // This browser's renderers by client id.
            var byClient: [Int: ProcessIdentity] = [:]
            var extensions: Set<ProcessIdentity> = []
            for p in childrenOf[browser.pid] ?? [] {
                guard let args = rendererArgs(p.identity) else { continue }
                byClient[args.clientID] = p.identity
                if args.isExtension { extensions.insert(p.identity) }
            }
            guard !byClient.isEmpty else { continue }

            var perProcess: [ProcessIdentity: [TabRef: ChromeTabEntry]] = [:]
            for (connection, table) in browserTables {
                for tab in table.tabs where !tab.discarded {
                    let ref = TabRef(connection: connection, tabId: tab.tabId)
                    let tabHost = ChromeTabHost.derive(url: tab.url)
                    for f in tab.frames where f.processId >= 0 {
                        guard let pid = byClient[f.processId] else { continue }
                        let existing = perProcess[pid]?[ref]
                        if f.frameId == 0 {
                            perProcess[pid, default: [:]][ref] = ChromeTabEntry(
                                kind: .tab, host: tabHost, title: ChromeTabHost.sanitizeTitle(tab.title), url: tab.url,
                                active: tab.active, audible: tab.audible, lastAccessed: tab.lastAccessed)
                        } else if existing == nil {
                            perProcess[pid, default: [:]][ref] = ChromeTabEntry(
                                kind: .frame(inTabHost: tabHost), host: ChromeTabHost.derive(origin: f.origin), title: "", url: "",
                                active: tab.active, audible: tab.audible, lastAccessed: tab.lastAccessed)
                        }
                    }
                }
            }
            for (pid, entries) in perProcess {
                out[pid] = ChromeTabAttribution(entries: Self.ordered(Array(entries.values)), isExtensionProcess: false)
            }
            for pid in extensions where out[pid] == nil { out[pid] = ChromeTabAttribution(entries: [], isExtensionProcess: true) }
        }
        return out
    }

    private func rendererArgs(_ id: ProcessIdentity) -> ChromeRendererArgs? {
        if let cached = cache[id] { return cached }
        guard let argv = arguments(id.pid) else { return nil }   // gone or unreadable: try again next time
        let parsed = ChromeRendererArgs.parse(argv)
        cache[id] = .some(parsed)
        return parsed
    }

    static func ordered(_ entries: [ChromeTabEntry]) -> [ChromeTabEntry] {
        entries.sorted { a, b in
            let at = a.kind == .tab, bt = b.kind == .tab
            if at != bt { return at }
            if a.active != b.active { return a.active }
            if a.lastAccessed != b.lastAccessed { return a.lastAccessed > b.lastAccessed }
            return (a.host, a.title) < (b.host, b.title)
        }
    }
}
