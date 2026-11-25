import Foundation
// Chrome tabs in MCP output. MCP clients usually forward what they get to a cloud model, so they see sites only: no
// URL, path, query or page title, and IP addresses and local network names (single-label, or ending in .local, .lan,
// .internal or .home.arpa) are generalised (ChromeTabHost.forMCP). The reduction happens once, here, when the view is built from the app's attribution.

public struct ChromeTabMCPEntry: Sendable, Equatable {
    public var host: String
    /// "tab", or "frame" for another site's frame inside a tab.
    public var kind: String
    public var active: Bool
    public var audible: Bool
    public init(host: String, kind: String, active: Bool, audible: Bool) { self.host = host; self.kind = kind; self.active = active; self.audible = audible }
}

public struct ChromeTabsView: Sendable, Equatable {
    public var byPID: [Int32: [ChromeTabMCPEntry]]

    public init(byPID: [Int32: [ChromeTabMCPEntry]]) { self.byPID = byPID }

    /// Drops titles and URLs and generalises every host.
    public init(_ attribution: [ProcessIdentity: ChromeTabAttribution]) {
        var out: [Int32: [ChromeTabMCPEntry]] = [:]
        for (id, a) in attribution where !a.entries.isEmpty {
            out[id.pid] = a.entries.map { e in
                ChromeTabMCPEntry(host: ChromeTabHost.forMCP(e.host), kind: e.kind == .tab ? "tab" : "frame", active: e.active, audible: e.audible)
            }
        }
        byPID = out
    }

    static func json(_ entries: [ChromeTabMCPEntry]) -> JSON {
        .array(entries.map { ["host": .string($0.host), "kind": .string($0.kind), "active": .bool($0.active), "audible": .bool($0.audible)] })
    }

    /// `[{host, kind, active, audible}]` for a renderer, nil for any other process.
    public func json(pid: Int32) -> JSON? { byPID[pid].map(Self.json) }

    /// The `list_processes` cell: every host of the renderer's tabs and frames, or null.
    public func hostsCell(pid: Int32) -> JSON { byPID[pid].map { .strings($0.map(\.host)) } ?? .null }

    /// A finding's entries: those of its processes, in order, without repeats; nil when none is a renderer.
    public func json(pids: [Int32]) -> JSON? {
        var seen: [ChromeTabMCPEntry] = []
        for p in pids { for e in byPID[p] ?? [] where !seen.contains(e) { seen.append(e) } }
        return seen.isEmpty ? nil : Self.json(seen)
    }

    public static let unavailable: JSON = MCPFormat.unavailable("Chrome tabs are off, not connected, or this is the standalone server")
    public static let note = " Chrome tabs: hosts only; FlightDeck never exposes tab URLs or titles."
}
