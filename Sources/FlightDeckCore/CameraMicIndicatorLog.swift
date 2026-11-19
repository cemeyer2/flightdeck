import Foundation
// Which app is using the camera or microphone, as macOS's own privacy indicator sees it. Control Center logs every
// change of its "sensor indicators" (the green and orange dots) to the unified log, subsystem com.apple.controlcenter,
// category sensor-indicators, with the bundle ID in public text:
//
//   Active activity attributions changed to ["mic:us.zoom.xos", "cam:us.zoom.xos"]
//   Sorted active attributions from SystemStatus update: [[mic] zoom.us (us.zoom.xos), [cam] zoom.us (us.zoom.xos)]
//
// Each such line is the complete set that is active right now (not a delta). The second form also carries the app's
// display name. Codes seen: "cam" (camera), "mic" (microphone), "aud" (system-audio recording, e.g. a process tap),
// "scr" (screen recording), "loc" (location). Only cam and mic are tracked; the others are parsed and ignored.
// "Recent activity attributions…" lists what *was* active a moment ago, so it's skipped. Other fields of these
// messages (bundle path, executable path, display name in the "attributed attribution" line) are <private>.
//
// Parsing is pure and tested on captured lines (CameraMicTests). Lines in an unexpected shape yield nil, never a
// guessed attribution.

/// One entry of the indicator's active set.
public struct IndicatorAttribution: Sendable, Hashable, Codable {
    /// The indicator's short code ("cam", "mic", "aud", "scr", "loc", …).
    public var code: String
    public var bundleID: String
    /// The display name, when the line carried one.
    public var name: String?
    public init(code: String, bundleID: String, name: String? = nil) { self.code = code; self.bundleID = bundleID; self.name = name }
    /// camera for "cam", microphone for "mic", nil for codes FlightDeck doesn't track.
    public var kind: SensorKind? { code == "cam" ? .camera : code == "mic" ? .microphone : nil }
}

public enum IndicatorLogParser {
    /// The `log` predicate: exactly the category that carries the indicator's state, so the stream sees a handful of
    /// lines per minute even on a busy Mac (logd evaluates it, so the rest of the log never reaches FlightDeck).
    public static let predicate = #"subsystem == "com.apple.controlcenter" AND category == "sensor-indicators""#

    static let activePrefix = "Active activity attributions changed to "
    static let sortedPrefix = "Sorted active attributions from SystemStatus update: "

    /// The active set from one message, or nil if the message isn't a statement of the active set.
    /// An empty array means "nothing is active".
    public static func parse(message m: String) -> [IndicatorAttribution]? {
        if let r = m.range(of: activePrefix) { return parseQuoted(m[r.upperBound...]) }
        if let r = m.range(of: sortedPrefix) { return parseBracketed(m[r.upperBound...]) }
        return nil
    }

    /// One ndjson line from `log stream/show --style ndjson`: its time and active set, or nil for any other line (the
    /// "Filtering the log data…" banner, other messages, a truncated line).
    public static func parse(ndjson line: Data) -> (time: Date?, active: [IndicatorAttribution])? {
        guard line.first == UInt8(ascii: "{"),
              let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let msg = o["eventMessage"] as? String, let active = parse(message: msg) else { return nil }
        return ((o["timestamp"] as? String).flatMap(LogParser.parseTimestamp), active)
    }

    /// `["mic:us.zoom.xos", "cam:us.zoom.xos"]`: quoted "code:bundle" items.
    static func parseQuoted(_ s: Substring) -> [IndicatorAttribution]? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        let body = t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return [] }
        var out: [IndicatorAttribution] = []
        for raw in body.split(separator: ",") {
            let item = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            // The bundle ID itself has no colon; split at the first one only, in case a code ever has more structure.
            guard let colon = item.firstIndex(of: ":") else { return nil }
            let code = String(item[..<colon]), bundle = String(item[item.index(after: colon)...])
            guard isCode(code), !bundle.isEmpty else { return nil }
            out.append(IndicatorAttribution(code: code, bundleID: bundle))
        }
        return out
    }

    /// `[[mic] zoom.us (us.zoom.xos), [aud] Audio Routing Kit (ARK) (com.rogueamoeba.arkaudiod)]`. Names may contain
    /// parentheses and commas, so items are found by their "[code] " openers, and the bundle ID is the last
    /// parenthesised group of each item.
    static func parseBracketed(_ s: Substring) -> [IndicatorAttribution]? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        let body = String(t.dropFirst().dropLast())
        if body.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        // Positions of every "[code] " opener: at the start, or right after ", ".
        var starts: [(code: String, nameStart: String.Index, itemStart: String.Index)] = []
        var i = body.startIndex
        while let open = body[i...].firstIndex(of: "[") {
            let atBoundary = open == body.startIndex || body[..<open].hasSuffix(", ")
            if atBoundary, let close = body[open...].firstIndex(of: "]") {
                let code = String(body[body.index(after: open)..<close])
                let after = body.index(after: close)
                if isCode(code), after < body.endIndex, body[after] == " " {
                    starts.append((code, body.index(after: after), open))
                    i = after; continue
                }
            }
            i = body.index(after: open)
        }
        guard !starts.isEmpty, starts[0].itemStart == body.startIndex else { return nil }
        var out: [IndicatorAttribution] = []
        for (k, st) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].itemStart : body.endIndex
            var item = body[st.nameStart..<end].trimmingCharacters(in: .whitespaces)
            if item.hasSuffix(",") { item.removeLast() }
            guard item.hasSuffix(")"), let open = item.lastIndex(of: "(") else { return nil }
            let bundle = String(item[item.index(after: open)..<item.index(before: item.endIndex)])
            let name = item[..<open].trimmingCharacters(in: .whitespaces)
            guard !bundle.isEmpty, !bundle.contains(" ") else { return nil }
            out.append(IndicatorAttribution(code: st.code, bundleID: bundle, name: name.isEmpty ? nil : name))
        }
        return out
    }

    /// Indicator codes are short lower-case words.
    static func isCode(_ s: String) -> Bool { (2...6).contains(s.count) && s.allSatisfy { $0.isLetter && $0.isLowercase } }
}
