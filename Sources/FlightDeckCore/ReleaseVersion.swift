// Release versions for update checks: the installed CFBundleShortVersionString and GitHub release tags, parsed as
// numbers ("1.10.0" > "1.9.0"). Only the short version is compared. The build number (the workflow run number for
// releases, `git describe` output for local builds) is used only to recognise bundle.sh's no-tags fallback, 1.0 build 1.
import Foundation

/// A dotted numeric version. Missing components count as 0, so 1.6 == 1.6.0.
public struct ReleaseVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// As parsed, e.g. [1, 7].
    public let components: [Int]
    public var description: String { components.map(String.init).joined(separator: ".") }

    /// Strict: an optional leading v/V, then digits separated by "."; nothing else.
    public init?(_ s: String) {
        var t = Substring(s.trimmingCharacters(in: .whitespaces))
        if t.first == "v" || t.first == "V" { t = t.dropFirst() }
        guard !t.isEmpty else { return nil }
        var parts: [Int] = []
        for p in t.split(separator: ".", omittingEmptySubsequences: false) {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            parts.append(n)
        }
        components = parts
    }

    /// Components without trailing zeros, so equality and hashing agree with the padded ordering.
    private var trimmed: ArraySlice<Int> {
        var c = components[...]
        while c.last == 0 { c = c.dropLast() }
        return c
    }

    public static func == (a: ReleaseVersion, b: ReleaseVersion) -> Bool { a.trimmed == b.trimmed }
    public func hash(into h: inout Hasher) { h.combine(Array(trimmed)) }
    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        for i in 0..<max(a.components.count, b.components.count) {
            let x = i < a.components.count ? a.components[i] : 0, y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// What a release tag says: a stable version, a pre-release that slipped through as "latest" (any "-" suffix; the
/// release workflow doesn't mark them), or something that isn't a version.
public enum RemoteTag: Sendable, Equatable { case stable(ReleaseVersion), prerelease, unparseable }

extension ReleaseVersion {
    /// The running copy's version; nil means unknown (`swift run`, no Info.plist, or bundle.sh's no-tags fallback),
    /// and update checks are skipped entirely. Anything from the first "-" or "+" is ignored.
    public static func installed(shortVersion: String?, build: String?) -> ReleaseVersion? {
        guard let s = shortVersion?.trimmingCharacters(in: .whitespaces) else { return nil }
        let core = s.prefix { $0 != "-" && $0 != "+" }
        if core == "1.0" && build?.trimmingCharacters(in: .whitespaces) == "1" { return nil }
        return ReleaseVersion(String(core))
    }

    /// A GitHub tag such as "v1.7.0". Build metadata ("+…") is dropped; a "-" suffix makes it a pre-release.
    public static func remote(tag: String) -> RemoteTag {
        var t = Substring(tag.trimmingCharacters(in: .whitespaces))
        if t.first == "v" || t.first == "V" { t = t.dropFirst() }
        if t.contains("-") { return .prerelease }
        return ReleaseVersion(String(t.prefix { $0 != "+" })).map { .stable($0) } ?? .unparseable
    }

    /// Strictly greater: a local build ahead of the release is never offered the older one.
    public static func isNewer(remote: ReleaseVersion, installed: ReleaseVersion) -> Bool { remote > installed }
}
