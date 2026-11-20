import Foundation
// Fleet, part 2: what of a finding may leave this Mac. A finding's ID can carry an app identifier or a PID, its
// `pids` name processes, and its wording can mention a volume path, a router's address or a host name, so only the
// kind (the ID up to its first ":"), severity, icon, start and a scrubbed title/detail are shared. Whole kinds that
// are about privacy (camera & mic use, new network destinations) are never shared at all.

public struct FleetRedaction: Sendable {
    /// Finding kinds that are never shared: camera/mic and destination alerts ("privacy:…") say what the user is doing.
    public static let withheldKinds: Set<String> = ["privacy"]
    /// Kinds whose detail is free text from an app (a sleep assertion's reason can name a document or download), so
    /// only the title is shared.
    public static let titleOnlyKinds: Set<String> = ["awake"]

    /// Words to remove wherever they appear (case-insensitive): the account's short and full name, and the home path.
    public var names: [String]

    public init(names: [String]) { self.names = names.filter { $0.count >= 2 }.sorted { $0.count > $1.count } }

    /// This account's names (short, full, and each part of the full name longer than 2 letters) and home folder.
    public static var current: FleetRedaction {
        let full = NSFullUserName()
        let parts = full.split(separator: " ").map(String.init).filter { $0.count > 2 }
        return FleetRedaction(names: [NSHomeDirectory(), NSUserName(), full] + parts)
    }

    public static func kind(of id: String) -> String {
        String(id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    public func finding(_ f: Finding) -> FleetFinding? {
        let k = Self.kind(of: f.id)
        guard !Self.withheldKinds.contains(k) else { return nil }
        return FleetFinding(kind: k, severity: f.severity.rawValue, icon: Self.icon(f.icon), title: scrub(f.title),
                            detail: Self.titleOnlyKinds.contains(k) ? nil : f.detail.map(scrub), since: f.since)
    }

    public func incident(_ i: Incident) -> FleetFinding? {
        let k = Self.kind(of: i.key)
        guard !Self.withheldKinds.contains(k) else { return nil }
        return FleetFinding(kind: k, severity: i.severity.rawValue, icon: Self.icon(i.icon), title: scrub(i.title),
                            detail: Self.titleOnlyKinds.contains(k) ? nil : i.detail.map(scrub), since: i.start, end: i.end)
    }

    /// SF Symbol names are short lowercase words with dots; anything else becomes a generic icon.
    static func icon(_ s: String) -> String {
        s.count <= 60 && s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }) ? s : "exclamationmark.circle"
    }

    /// Replaces the user's names, paths, URLs, e-mail addresses, IP and MAC addresses and host names.
    public func scrub(_ text: String) -> String {
        var s = text
        func apply(_ list: ArraySlice<(NSRegularExpression, String)>) {
            for (pattern, replacement) in list { s = pattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: replacement) }
        }
        // Links, e-mail addresses and paths first (they contain names), then names as whole words (so a short account
        // name like "al" doesn't eat "Already"), then addresses and host names.
        apply(Self.patterns.prefix(3))
        for n in names {
            let re = try? NSRegularExpression(pattern: #"(?<![\w])"# + NSRegularExpression.escapedPattern(for: n) + #"(?![\w])"#, options: .caseInsensitive)
            s = re?.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "‹user›") ?? s
        }
        apply(Self.patterns.dropFirst(3))
        return String(s.prefix(240))
    }

    /// Order matters: URLs and e-mail before paths and host names, which they contain.
    static let patterns: [(NSRegularExpression, String)] = [
        (#"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s)\]"']+"#, "‹link›"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "‹email›"),
        // ~/x, /x/y, "/Volumes/Data" (not "MB/s" or "1/2": the character before the slash must not be a word character).
        (#"(?<![\w.])~?/(?:[^\s/,;()\[\]"']+/)*[^\s/,;()\[\]"']+/?"#, "‹path›"),
        // MAC addresses, then IPv6 (needs "::" or a hex letter so "12:30:05" stays), then IPv4.
        (#"\b[0-9A-Fa-f]{1,2}(?::[0-9A-Fa-f]{1,2}){5}\b"#, "‹address›"),
        (#"(?<![\w:])(?=[0-9A-Fa-f:]*(?:::|[A-Fa-f]))[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:%\w+)?(?![\w:])"#, "‹address›"),
        (#"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b"#, "‹address›"),
        // Host names: dotted labels ending in a 2+ letter label ("nas.local", "example.com", "com.apple.Safari").
        (#"\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}\b"#, "‹host›"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}
