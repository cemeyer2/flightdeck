import Foundation
// Chrome tabs: the messages between the extension, the native host and the app, and their strict validation. The
// extension's data is untrusted input (anyone can load an unpacked extension with our public key), so a malformed
// message is refused whole: unknown types, missing fields, non-integer integers, more tabs than `ChromeTabsConstants`
// allows or an over-long hello/origin make `parse` return nil. A well-formed tab over one of the per-tab limits (a string
// too long, too many frames) is left out of the table instead, so one long URL can't hide every other tab in the profile.
// None of these types is Codable, so tab data can't be saved by accident.

public struct ChromeRawFrame: Sendable, Hashable {
    public var frameId: Int
    public var parentFrameId: Int
    /// Chrome's render process id, which equals the renderer's `--renderer-client-id`.
    public var processId: Int
    /// The frame's origin only (the extension never sends a frame's full URL).
    public var origin: String
    public init(frameId: Int, parentFrameId: Int, processId: Int, origin: String) {
        self.frameId = frameId; self.parentFrameId = parentFrameId; self.processId = processId; self.origin = origin
    }
}

public struct ChromeRawTab: Sendable, Hashable {
    public var tabId: Int
    public var windowId: Int
    public var active: Bool
    public var audible: Bool
    public var discarded: Bool
    public var url: String
    public var title: String
    /// Milliseconds since 1970 (Chrome's `tab.lastAccessed`).
    public var lastAccessed: Double
    public var frames: [ChromeRawFrame]
    public init(tabId: Int, windowId: Int, active: Bool, audible: Bool, discarded: Bool, url: String, title: String,
                lastAccessed: Double, frames: [ChromeRawFrame]) {
        self.tabId = tabId; self.windowId = windowId; self.active = active; self.audible = audible; self.discarded = discarded
        self.url = url; self.title = title; self.lastAccessed = lastAccessed; self.frames = frames
    }
}

/// One complete tab table from one extension connection (one Chrome profile).
public struct ChromeTabTable: Sendable, Hashable {
    public var seq: Int
    public var tabs: [ChromeRawTab]
    public init(seq: Int, tabs: [ChromeRawTab]) { self.seq = seq; self.tabs = tabs }
}

public enum ChromeTabsMessage: Sendable, Equatable {
    /// extension → host → app, first on every port.
    case hello(protocol: Int, extensionVersion: String)
    /// extension → host → app: the full table, never a diff.
    case tabs(ChromeTabTable)
    /// host → app only: the first frame on each socket connection, the origin Chrome launched the host with.
    case origin(String)
    /// host → extension: send the table again (the app has just connected).
    case refresh

    /// The validated message, or nil when anything about it is malformed. A table leaves out only its oversized tabs.
    public static func parse(_ data: Data) -> ChromeTabsMessage? {
        guard let json = try? JSON.parse(data), json.isObject, let type = json["type"]?.string else { return nil }
        switch type {
        case "hello":
            guard let p = strictInt(json["protocol"]), let v = json["extensionVersion"]?.string, v.utf8.count <= 64 else { return nil }
            return .hello(protocol: p, extensionVersion: v)
        case "origin":
            guard let o = json["origin"]?.string, o.utf8.count <= ChromeTabsConstants.maxOriginBytes else { return nil }
            return .origin(o)
        case "refresh":
            return .refresh
        case "tabs":
            guard let seq = strictInt(json["seq"]), let raw = json["tabs"]?.array, raw.count <= ChromeTabsConstants.maxTabs else { return nil }
            var tabs: [ChromeRawTab] = []
            tabs.reserveCapacity(raw.count)
            for t in raw {
                switch parseTab(t) {
                case .tab(let tab): tabs.append(tab)
                case .oversized: continue
                case .malformed: return nil
                }
            }
            return .tabs(ChromeTabTable(seq: seq, tabs: tabs))
        default:
            return nil
        }
    }

    public func encoded() -> Data {
        switch self {
        case .hello(let p, let v): return (["type": "hello", "protocol": .int(p), "extensionVersion": .string(v)] as JSON).data
        case .origin(let o): return (["type": "origin", "origin": .string(o)] as JSON).data
        case .refresh: return (["type": "refresh"] as JSON).data
        case .tabs(let t):
            let tabs: [JSON] = t.tabs.map { tab in
                ["tabId": .int(tab.tabId), "windowId": .int(tab.windowId), "active": .bool(tab.active), "audible": .bool(tab.audible),
                 "discarded": .bool(tab.discarded), "url": .string(tab.url), "title": .string(tab.title),
                 "lastAccessed": .double(tab.lastAccessed),
                 "frames": .array(tab.frames.map { f in
                     ["frameId": .int(f.frameId), "parentFrameId": .int(f.parentFrameId), "processId": .int(f.processId),
                      "origin": .string(f.origin)] as JSON
                 })]
            }
            return (["type": "tabs", "seq": .int(t.seq), "tabs": .array(tabs)] as JSON).data
        }
    }

    // A JSON integer only: 1.5, "3", true and 3.0 are all refused.
    private static func strictInt(_ j: JSON?) -> Int? { if case .int(let i)? = j { return i }; return nil }
    private static func strictBool(_ j: JSON?) -> Bool? { if case .bool(let b)? = j { return b }; return nil }
    private static func string(_ j: JSON?) -> String? { if case .string(let s)? = j { return s }; return nil }

    private enum TabParse { case tab(ChromeRawTab), oversized, malformed }

    // Every field's type is checked before any size, so an oversized tab is still a well-formed one.
    private static func parseTab(_ t: JSON) -> TabParse {
        guard t.isObject,
              let tabId = strictInt(t["tabId"]), let windowId = strictInt(t["windowId"]),
              let active = strictBool(t["active"]), let audible = strictBool(t["audible"]), let discarded = strictBool(t["discarded"]),
              let url = string(t["url"]), let title = string(t["title"]),
              let last = lastAccessed(t["lastAccessed"]),
              let rawFrames = t["frames"]?.array else { return .malformed }
        var frames: [ChromeRawFrame] = []
        frames.reserveCapacity(min(rawFrames.count, ChromeTabsConstants.maxFramesPerTab))
        for f in rawFrames {
            guard f.isObject, let id = strictInt(f["frameId"]), let parent = strictInt(f["parentFrameId"]),
                  let process = strictInt(f["processId"]), let origin = string(f["origin"]) else { return .malformed }
            frames.append(ChromeRawFrame(frameId: id, parentFrameId: parent, processId: process, origin: origin))
        }
        guard url.utf8.count <= ChromeTabsConstants.maxURLBytes, title.utf8.count <= ChromeTabsConstants.maxTitleBytes,
              frames.count <= ChromeTabsConstants.maxFramesPerTab,
              frames.allSatisfy({ $0.origin.utf8.count <= ChromeTabsConstants.maxOriginBytes }) else { return .oversized }
        return .tab(ChromeRawTab(tabId: tabId, windowId: windowId, active: active, audible: audible, discarded: discarded,
                                 url: url, title: title, lastAccessed: last, frames: frames))
    }

    private static func lastAccessed(_ j: JSON?) -> Double? {
        switch j {
        case .int(let i)?: return Double(i)
        case .double(let d)? where d.isFinite: return d
        default: return nil
        }
    }
}
