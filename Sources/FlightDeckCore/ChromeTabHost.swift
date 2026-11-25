import Foundation
import Darwin
// Chrome tabs: the site shown for a tab, worked out from its URL here rather than taken from the extension, and the
// clean-up of page titles. A page sets its own title, so control, newline and bidi characters are removed before it is
// shown: a title can't break a row onto two lines or reorder the text around it to pose as another process.

public enum ChromeTabHost {
    /// The site of a tab's URL:
    /// - http/https: the host, lowercased. Internationalised names stay in punycode (`xn--…`), never decoded, so a
    ///   lookalike script can't imitate another site; `www.` is kept.
    /// - file → "local file"; data and blob → "embedded page"; chrome, chrome-extension, devtools and about → "Chrome page";
    ///   anything else → "page".
    public static func derive(url: String) -> String {
        guard let colon = url.firstIndex(of: ":") else { return "page" }
        switch url[..<colon].lowercased() {
        case "http", "https":
            guard let c = URLComponents(string: url), let h = c.percentEncodedHost ?? c.host, !h.isEmpty else { return "page" }
            return h.lowercased()
        case "file": return "local file"
        case "data", "blob": return "embedded page"
        case "chrome", "chrome-extension", "devtools", "about": return "Chrome page"
        default: return "page"
        }
    }

    /// The same rules for a frame's origin ("https://ads.example.net", or "null" for an opaque one).
    public static func derive(origin: String) -> String { derive(url: origin) }

    /// The form a host takes in MCP output, which usually goes on to a cloud model: an IP literal becomes "IP address" and
    /// a single-label name (an intranet host such as `wiki`, or `localhost`) becomes "local network host". Dotted names
    /// and the fixed labels ("local file", …) pass through.
    public static func forMCP(_ host: String) -> String {
        if fixedLabels.contains(host) { return host }
        if isIPLiteral(host) { return "IP address" }
        if !host.contains(".") { return "local network host" }
        return host
    }

    static let fixedLabels: Set<String> = ["local file", "embedded page", "Chrome page", "page"]

    static func isIPLiteral(_ host: String) -> Bool {
        var h = host
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }   // zone id: fe80::1%en0, or %25en0 in a URL
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, h, &v4) == 1 || inet_pton(AF_INET6, h, &v6) == 1
    }

    static let bidi: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
    public static let maxTitleCharacters = 200

    /// A page title made safe to show: whitespace controls (tab, newline, …) become spaces; other C0/C1 controls and
    /// bidi formatting characters are removed; runs of whitespace collapse to one space; at most 200 characters.
    public static func sanitizeTitle(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            if u.properties.isWhitespace { scalars.append(" ") }
            else if u.properties.generalCategory == .control || bidi.contains(u.value) { continue }
            else { scalars.append(u) }
        }
        let collapsed = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(maxTitleCharacters))
    }
}
