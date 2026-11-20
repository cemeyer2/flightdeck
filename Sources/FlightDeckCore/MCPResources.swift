import Foundation
// MCP resources: a few fixed URIs a client can read and subscribe to, so it is told when something happens instead of
// polling. Reading one returns the same JSON as the matching tool with its default arguments (no second collector).
// Notifications carry the event itself in `_meta["app.flightdeck/event"]`, so a client can act without re-reading.

public struct MCPResourceSpec: Sendable {
    public var uri, name, title, description: String
}

/// Resources a server exposes, and the hub whose events update them.
public protocol MCPResourceProvider: Sendable {
    var resources: [MCPResourceSpec] { get }
    /// The resource's text (JSON), or nil if there is no such resource.
    func read(_ uri: String) async -> String?
    var events: MCPEventHub? { get }
}

public enum MCPResources {
    public static let events = "flightdeck://events", incidents = "flightdeck://incidents", findings = "flightdeck://findings"
    public static let reports = "flightdeck://reports", status = "flightdeck://status"
    static let eventMetaKey = "app.flightdeck/event"
    static let subscriptionKey = "io.modelcontextprotocol/subscriptionId"

    public static let all: [MCPResourceSpec] = [
        .init(uri: events, name: "events", title: "FlightDeck events",
              description: "The latest events pushed to subscribers (incidents opening and closing, new findings, crash/hang/panic reports, thermal state changes, low battery), newest first. Subscribe to be told about every event."),
        .init(uri: incidents, name: "incidents", title: "Flight Log",
              description: "The Flight Log's last 24 h (as recent_incidents). Updated when an incident opens or closes."),
        .init(uri: findings, name: "findings", title: "Current findings",
              description: "What's wrong right now (as get_status). Updated when a new finding appears or one gets worse."),
        .init(uri: reports, name: "reports", title: "Crash and hang reports",
              description: "macOS crash, hang, memory-kill and panic reports of the last 24 h (as diagnostic_reports). Updated when a new report appears."),
        .init(uri: status, name: "status", title: "System status",
              description: "The system status (as get_status). Updated when the thermal state changes or the battery runs low."),
    ]

    /// Whether a client subscribed to `uris` wants `e`.
    static func wants(_ uris: Set<String>, _ e: MCPEvent) -> Bool { uris.contains(events) || uris.contains(e.uri) }

    static func listJSON(_ list: [MCPResourceSpec]) -> JSON {
        .array(list.map { ["uri": .str($0.uri), "name": .str($0.name), "title": .str($0.title), "description": .str($0.description), "mimeType": "application/json"] })
    }

    /// `notifications/resources/updated` for `e` on `uri`; with `subscription`, as a 2026-07-28 `subscriptions/listen` stream sends it.
    public static func updated(_ e: MCPEvent, uri: String, subscription: JSON? = nil) -> JSON {
        var meta: [(String, JSON)] = [(eventMetaKey, e.json)]
        if let subscription { meta.insert((subscriptionKey, subscription), at: 0) }
        return ["jsonrpc": "2.0", "method": "notifications/resources/updated", "params": ["uri": .str(uri), "_meta": .object(meta)]]
    }

    /// The URI to name in a notification for `e` to a client subscribed to `uris`: the event's own resource if
    /// subscribed, else the events feed.
    static func uri(for e: MCPEvent, in uris: Set<String>) -> String { uris.contains(e.uri) ? e.uri : events }

    /// A Claude Code channel event (`notifications/claude/channel`): plain text for the model, string attributes in
    /// `meta` (identifier keys only, or Claude Code drops them).
    public static func channel(_ e: MCPEvent) -> JSON {
        func sentence(_ s: String) -> String { s.hasSuffix(".") ? s : s + "." }
        var text = sentence(e.title) + (e.detail.map { " " + sentence($0) } ?? "")
        let withPID = e.nextTool == "get_process" || e.nextTool == "sample_stacks"
        text += " Since \(MCPFormat.time(e.since).string ?? ""). For details call \(e.nextTool)" + (withPID ? e.pid.map { " with pid \($0)" } ?? "" : "") + "."
        let meta: JSON = .object(dropping: [
            ("event", .str(e.kind.rawValue)), ("severity", MCPFormat.severity(e.severity)), ("app", e.app.map(JSON.str)),
            ("pid", e.pid.map { .str(String($0)) }), ("since", MCPFormat.time(e.since)), ("uri", .str(e.uri)), ("seq", .str(String(e.seq))),
        ])
        return ["jsonrpc": "2.0", "method": "notifications/claude/channel", "params": ["content": .str(text), "meta": meta]]
    }

    /// The event carried by a notification (any of the shapes above), for the stdio proxy relaying the app's stream.
    static func event(in notification: JSON) -> MCPEvent? {
        notification["params"]?["_meta"]?[eventMetaKey].flatMap(MCPEvent.init(json:))
    }
}

extension MCPTools: MCPResourceProvider {
    public var resources: [MCPResourceSpec] { MCPResources.all }

    public func read(_ uri: String) async -> String? {
        let tool: String
        switch uri {
        case MCPResources.events:
            let list = (events?.recentEvents() ?? []).reversed()
            return object([("now", F.time(now())),
                           ("summary", .str(list.isEmpty ? "No events since this server started listening (events are only watched while a client subscribes or waits)." : "\(list.count) recent event\(list.count == 1 ? "" : "s"), newest first.")),
                           ("events", .array(list.map(\.json)))]).text
        case MCPResources.incidents: tool = "recent_incidents"
        case MCPResources.findings, MCPResources.status: tool = "get_status"
        case MCPResources.reports: tool = "diagnostic_reports"
        default: return nil
        }
        return await call(tool, arguments: .object([])).text
    }
}
