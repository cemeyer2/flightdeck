// GitHub's latest release for update checks: decoding the `/releases/latest` body, and the one rule for which links
// FlightDeck will open. A link from the response is used only if it points at this repo's releases on github.com;
// otherwise the release page is built from the (already validated) tag. Never an arbitrary URL from the response.
import Foundation

/// The repository update checks ask about. Later files extend this namespace with the check's rules.
public enum ReleaseCheck {
    public static let owner = "cemeyer2"
    public static let repo = "flightdeck"
}

/// The newest stable release, as Settings and the notification show it.
public struct ReleaseInfo: Sendable, Equatable {
    public var tag: String
    public var version: ReleaseVersion
    public var name: String?
    /// Always a validated link to this repo's releases (see `releaseURL`).
    public var url: URL
    public var publishedAt: Date?

    public init(tag: String, version: ReleaseVersion, name: String? = nil, url: URL, publishedAt: Date? = nil) {
        self.tag = tag; self.version = version; self.name = name; self.url = url; self.publishedAt = publishedAt
    }
}

/// What a `/releases/latest` body says. `noStableRelease` (a draft, or a pre-release published as latest) is not an
/// error: Settings shows "up to date". `unreadable` is non-JSON, no tag, or a tag that isn't a version.
public enum ReleaseDecode: Sendable, Equatable { case stable(ReleaseInfo), noStableRelease, unreadable }

extension ReleaseInfo {
    private struct DTO: Decodable {
        var tag_name: String
        var name: String?
        var html_url: String?
        var published_at: String?
        var prerelease: Bool?
        var draft: Bool?
    }

    public static func decode(_ data: Data) -> ReleaseDecode {
        guard let d = try? JSONDecoder().decode(DTO.self, from: data) else { return .unreadable }
        if d.draft == true || d.prerelease == true { return .noStableRelease }
        switch ReleaseVersion.remote(tag: d.tag_name) {
        case .prerelease: return .noStableRelease
        case .unparseable: return .unreadable
        case .stable(let version):
            let published = d.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
            return .stable(ReleaseInfo(tag: d.tag_name, version: version, name: d.name,
                                       url: releaseURL(htmlURL: d.html_url, tag: d.tag_name), publishedAt: published))
        }
    }

    private static var releasesPath: String { "/\(ReleaseCheck.owner)/\(ReleaseCheck.repo)/releases/" }

    /// https, host exactly "github.com" (any case), no user/password/port/query/fragment, and a path under this repo's
    /// releases with no "." or ".." segment (percent-encoded ones included).
    public static func isTrustedReleaseURL(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", c.percentEncodedHost?.lowercased() == "github.com",
              c.percentEncodedUser == nil, c.percentEncodedPassword == nil, c.port == nil,
              c.percentEncodedQuery == nil, c.percentEncodedFragment == nil else { return false }
        let path = c.percentEncodedPath
        guard path.hasPrefix(releasesPath) else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { seg in
            let s = seg.removingPercentEncoding ?? String(seg)
            return s == "." || s == ".."
        }
    }

    /// The validated `html_url`, else https://github.com/<owner>/<repo>/releases/tag/<tag, percent-encoded>.
    /// `tag` must already have passed `ReleaseVersion.remote` as `.stable`.
    public static func releaseURL(htmlURL: String?, tag: String) -> URL {
        if let s = htmlURL, let u = URL(string: s), isTrustedReleaseURL(u) { return u }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "+/")
        let t = tag.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://github.com\(releasesPath)tag/\(t)")!
    }
}
