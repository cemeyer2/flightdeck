import Foundation
// "What is this process?": a bundled, offline catalog of plain-English explanations, and the matcher that decides
// which entry (if any) a process gets. The entries live in the ProcessCatalog*.swift part files; the wording built from
// them is in ProcessCatalogText.swift.

/// One catalog entry: what a program is, who makes it, when it's normally busy, and whether quitting it helps.
/// Every entry is drafted from a source a reviewer can check (`groundedIn`); nothing here is generated at runtime.
public struct ProcessExplanation: Sendable, Hashable {
    public enum Maker: Sendable, Hashable { case apple; case vendor(String) }
    public enum QuitSafety: String, Sendable, Hashable, CaseIterable {
        /// Quitting is harmless; it starts again when it's needed.
        case safe
        /// launchd starts it again within seconds, so quitting doesn't help.
        case relaunches
        /// Quitting interrupts something you'd notice (sound, sync, the display, the login session).
        case avoid
        /// Part of macOS itself: quitting logs you out, freezes or restarts the Mac.
        case never
        /// An ordinary app the user opened: quitting it is safe once its work is saved.
        case app
    }
    public var id: String
    public var title: String
    /// What it does, in one or two sentences.
    public var summary: String
    public var maker: Maker
    /// When it's normally busy and why; nil when no source says.
    public var busyWhen: String?
    public var quit: QuitSafety
    /// What to do if it misbehaves; nil = no advice beyond `quit`.
    public var whatToDo: String?
    /// The short line added to findings about it.
    public var findingNote: String
    /// Corporate security or device-management software: "Managed by your organisation", never a suggestion to quit.
    public var managed: Bool
    // Match keys. `names` are display names as FlightDeck shows them (`ProcessSample.name`), not raw executable names.
    public var names: [String]
    public var namePrefixes: [String]
    public var paths: [String]
    public var pathPrefixes: [String]
    /// Code-signing identifiers of the outermost `.app` or bare executable.
    public var bundleIDs: [String]
    /// Vendor entries: the signing teams expected; empty = not checked.
    public var teamIDs: [String]
    /// The sources the text came from, separated by "; ": https URLs, x-man-page://<section>/<page> or file:///<path>.
    public var groundedIn: String

    public init(id: String, title: String, summary: String, maker: Maker, busyWhen: String? = nil, quit: QuitSafety,
                whatToDo: String? = nil, findingNote: String, managed: Bool = false, names: [String] = [],
                namePrefixes: [String] = [], paths: [String] = [], pathPrefixes: [String] = [], bundleIDs: [String] = [],
                teamIDs: [String] = [], groundedIn: String) {
        self.id = id; self.title = title; self.summary = summary; self.maker = maker; self.busyWhen = busyWhen
        self.quit = quit; self.whatToDo = whatToDo; self.findingNote = findingNote; self.managed = managed
        self.names = names; self.namePrefixes = namePrefixes; self.paths = paths; self.pathPrefixes = pathPrefixes
        self.bundleIDs = bundleIDs; self.teamIDs = teamIDs; self.groundedIn = groundedIn
    }

    public var isApple: Bool { maker == .apple }
    /// "Apple" or the vendor's name.
    public var makerName: String {
        switch maker { case .apple: return "Apple"; case .vendor(let v): return v }
    }
}

/// Which key matched. Raw values are what MCP reports as `matched_by`.
public enum MatchKey: String, Sendable {
    case path, pathPrefix = "path_prefix", name, namePrefix = "name_prefix", bundleID = "bundle_id"
}

/// Why a process is only a lookalike: it isn't where the entry's program lives, or it's where it lives but signed by
/// someone else.
public enum LookalikeReason: Sendable, Hashable { case location, signer }

public enum ProcessMatch: Sendable, Hashable {
    /// `pathVerified` is false when the path was unreadable and the match rests on the name alone.
    case known(ProcessExplanation, by: MatchKey, pathVerified: Bool)
    /// Named like a catalogued program but not where (or not signed by whom) it should be. Shown only in the inspector;
    /// everywhere else it is treated exactly like an unknown process.
    case lookalike(ProcessExplanation, LookalikeReason)
    case unknown

    /// The entry, for a vouched-for match only.
    public var known: ProcessExplanation? { if case .known(let e, _, _) = self { return e }; return nil }
}

/// The catalog, indexed once so a Processes row costs a few dictionary hits plus a short prefix scan, with no I/O and
/// no signature checks.
public struct ProcessCatalog: Sendable {
    public let entries: [ProcessExplanation]
    private let byID: [String: ProcessExplanation]
    private let byPath: [String: ProcessExplanation]
    private let byName: [String: ProcessExplanation]
    private let byBundleID: [String: ProcessExplanation]
    /// Path prefixes with at least two whole components, bucketed by those two ("/Applications/Dropbox.app/"), and the
    /// rest. Each list is sorted longest first, so the first hit in a list is its longest.
    private let pathBuckets: [String: [(String, ProcessExplanation)]]
    private let shortPathPrefixes: [(String, ProcessExplanation)]
    private let namePrefixes: [(String, ProcessExplanation)]

    public static let shared = ProcessCatalog(entries: ProcessCatalogParts.all)

    public init(entries: [ProcessExplanation]) {
        self.entries = entries
        func index(_ keys: (ProcessExplanation) -> [String]) -> [String: ProcessExplanation] {
            var d: [String: ProcessExplanation] = [:]
            for e in entries { for k in keys(e) where d[k] == nil { d[k] = e } }
            return d
        }
        byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        byPath = index(\.paths); byName = index(\.names); byBundleID = index(\.bundleIDs)
        func longestFirst(_ l: [(String, ProcessExplanation)]) -> [(String, ProcessExplanation)] { l.sorted { $0.0.count > $1.0.count } }
        var buckets: [String: [(String, ProcessExplanation)]] = [:], short: [(String, ProcessExplanation)] = []
        for e in entries {
            for p in e.pathPrefixes {
                if let b = Self.bucket(p) { buckets[b, default: []].append((p, e)) } else { short.append((p, e)) }
            }
        }
        pathBuckets = buckets.mapValues(longestFirst)
        shortPathPrefixes = longestFirst(short)
        namePrefixes = longestFirst(entries.flatMap { e in e.namePrefixes.map { ($0, e) } })
    }

    /// The first two whole path components ("/Applications/Dropbox.app/"), or nil if `p` has fewer.
    static func bucket(_ p: String) -> String? {
        guard p.hasPrefix("/") else { return nil }
        var slashes = 0
        for i in p.indices where p[i] == "/" {
            slashes += 1
            if slashes == 3 { return String(p[...i]) }
        }
        return nil
    }

    public func entry(id: String) -> ProcessExplanation? { byID[id] }

    /// FlightDeck's own process is FlightDeck wherever it runs from (~/Applications, Downloads, a build folder), so the
    /// inspector never calls it a lookalike of itself; so is another PID running the same executable (`--mcp`, the
    /// Chrome native host). Any other process goes through `lookup(name:path:signature:)`.
    public func lookup(pid: Int32, name: String, path: String, signature: ProcessDetails.Signature?) -> ProcessMatch {
        lookup(pid: pid, name: name, path: path, signature: signature, ownExecutable: Self.ownExecutable)
    }

    func lookup(pid: Int32, name: String, path: String, signature: ProcessDetails.Signature?, ownExecutable: String?) -> ProcessMatch {
        let mine = pid == getpid() || (!path.isEmpty && path == ownExecutable)
        if mine, let me = byID[Self.selfID] { return .known(me, by: .path, pathVerified: true) }
        return lookup(name: name, path: path, signature: signature)
    }

    static let selfID = "flightdeck"
    /// This process's executable with symlinks resolved, as process paths are reported.
    static let ownExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath().path

    /// Which entry this process gets. Precedence, first hit wins: exact path, longest path prefix, exact name, longest
    /// name prefix, then (only with a signature, and only when nothing else matched) bundle ID. A signature can change
    /// whether an entry is vouched for, or find one when nothing else did, but never picks a different entry than the
    /// row (which has no signature) would.
    public func lookup(name: String, path: String, signature: ProcessDetails.Signature?) -> ProcessMatch {
        if !path.isEmpty {
            if let e = byPath[path] { return judge(e, .path, path: path, signature: signature) }
            if let e = longestPathPrefix(path) { return judge(e, .pathPrefix, path: path, signature: signature) }
        }
        if let e = byName[name] { return judge(e, .name, path: path, signature: signature) }
        if let e = namePrefixes.first(where: { name.hasPrefix($0.0) })?.1 { return judge(e, .namePrefix, path: path, signature: signature) }
        if let s = signature, let id = s.identifier, let e = byBundleID[id] {
            let ok = e.isApple ? (s.isApple && s.valid) : (s.valid && s.teamID.map(e.teamIDs.contains) == true)
            return ok ? .known(e, by: .bundleID, pathVerified: true) : .lookalike(e, .signer)
        }
        return .unknown
    }

    /// An app-group row or finding. `groupKey` is `AppUsage.id`: a bundle path is looked up as that folder (so it lands
    /// on the app entry's path prefix), and "proc:<name>" by its name plus a member's path, so the lookalike guard applies.
    public func lookup(groupKey: String, name: String, memberPath: String) -> ProcessMatch {
        if groupKey.hasPrefix("proc:") { return lookup(name: String(groupKey.dropFirst(5)), path: memberPath, signature: nil) }
        return lookup(name: name, path: groupKey + "/", signature: nil)
    }

    /// The member to inspect for an app group: the app's main executable (<bundle>/Contents/MacOS/<file>, not a nested
    /// helper app), otherwise the first member.
    public static func mainMember(groupKey: String, _ members: [ProcessSample]) -> ProcessSample? {
        let dir = groupKey + "/Contents/MacOS/"
        return members.first { $0.path.hasPrefix(dir) && !$0.path.dropFirst(dir.count).contains(".app/") } ?? members.first
    }

    private func longestPathPrefix(_ path: String) -> ProcessExplanation? {
        let long = Self.bucket(path).flatMap { pathBuckets[$0] }?.first { path.hasPrefix($0.0) }
        let short = shortPathPrefixes.first { path.hasPrefix($0.0) }
        switch (long, short) {
        case let (l?, s?): return l.0.count >= s.0.count ? l.1 : s.1
        case let (l?, nil): return l.1
        case let (nil, s?): return s.1
        default: return nil
        }
    }

    /// The lookalike guard. Apple entries are vouched for only in macOS's own folders, with an unreadable path, or with
    /// a valid Apple signature. Vendor entries matched by path fail only on a signing-team mismatch; matched by name, a
    /// valid signature from the entry's team vouches for any location, and without one the path must be unreadable or
    /// inside one of the entry's own locations.
    private func judge(_ e: ProcessExplanation, _ key: MatchKey, path: String, signature: ProcessDetails.Signature?) -> ProcessMatch {
        if e.isApple {
            if path.isEmpty { return .known(e, by: key, pathVerified: false) }
            if Platform.isPlatformPath(path) || signature.map({ $0.isApple && $0.valid }) == true { return .known(e, by: key, pathVerified: true) }
            return .lookalike(e, .location)
        }
        if let s = signature, !e.teamIDs.isEmpty, !(s.teamID.map(e.teamIDs.contains) ?? false) { return .lookalike(e, .signer) }
        let signedByTeam = signature?.valid == true && !e.teamIDs.isEmpty
        switch key {
        case .path, .pathPrefix: return .known(e, by: key, pathVerified: true)
        case _ where signedByTeam: return .known(e, by: key, pathVerified: true)
        default:
            if path.isEmpty { return .known(e, by: key, pathVerified: false) }
            let own = e.paths.contains(path) || e.pathPrefixes.contains { path.hasPrefix($0) }
            return own ? .known(e, by: key, pathVerified: true) : .lookalike(e, .location)
        }
    }
}
