import Foundation

// "What Changed": FlightDeck takes an inventory of what is installed and configured to run on this Mac (launch agents
// and daemons, system and kernel extensions, configuration profiles, sharing services, apps, Homebrew packages, the
// macOS version), compares it with the previous one and records each difference as a ChangeEvent. Read-only, no root:
// whatever can't be read is listed with the reason. Readers are in ChangeReaders.swift, the comparison and the
// "why it may matter" rules in ChangeDiff.swift, persistence and findings in ChangeStore.swift.

/// What part of the Mac an inventory item belongs to.
public enum ChangeCategory: String, Codable, Sendable, CaseIterable, Identifiable, Comparable {
    case macOS, launchItem, systemExtension, kernelExtension, profile, sharing, app, homebrew
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .macOS: "macOS"
        case .launchItem: "Launch agents & daemons"
        case .systemExtension: "System extensions"
        case .kernelExtension: "Kernel extensions"
        case .profile: "Profiles & managed settings"
        case .sharing: "Sharing services"
        case .app: "Apps"
        case .homebrew: "Homebrew"
        }
    }
    /// Singular noun for sentences ("New app", "Launch item removed").
    public var noun: String {
        switch self {
        case .macOS: "macOS"; case .launchItem: "launch item"; case .systemExtension: "system extension"
        case .kernelExtension: "kernel extension"; case .profile: "profile"; case .sharing: "sharing service"
        case .app: "app"; case .homebrew: "Homebrew package"
        }
    }
    /// The sidebar page that shows this kind of item in full, if there is one (Destination raw value).
    public var page: String? {
        switch self {
        case .launchItem: "Startup Apps"; case .app: "Installed Apps"
        case .systemExtension, .kernelExtension: "Checkup"; default: nil
        }
    }
    /// Short names for the MCP `kind` filter.
    public var slug: String {
        switch self {
        case .macOS: "macos"; case .launchItem: "launch_items"; case .systemExtension: "system_extensions"
        case .kernelExtension: "kernel_extensions"; case .profile: "profiles"; case .sharing: "sharing"
        case .app: "apps"; case .homebrew: "homebrew"
        }
    }
    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

/// How an item's code is signed, as far as a static check can tell.
public enum SignatureState: String, Codable, Sendable, Hashable {
    case apple, developer, adHoc, unsigned, unknown
    public var isWeak: Bool { self == .adHoc || self == .unsigned }

    /// From a ProcessInspector signature (nil = the file couldn't be opened as code).
    public static func of(_ s: ProcessDetails.Signature?) -> SignatureState {
        guard let s else { return .unknown }
        if !s.valid { return .unsigned }
        if s.isApple { return .apple }
        return s.authority.isEmpty && s.teamID == nil ? .adHoc : .developer
    }
}

/// One thing in an inventory. `key` is unique within its category (a plist path, an app path, a bundle id).
public struct InventoryItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String { category.rawValue + ":" + key }
    public var category: ChangeCategory
    public var key: String
    public var name: String
    public var version: String?
    /// Launch item kind ("Launch Agent (User)"), Homebrew "formula"/"cask", profile scope, and so on.
    public var scope: String?
    /// The item's file (plist, bundle, Cellar folder).
    public var path: String?
    /// The program a launch item runs.
    public var program: String?
    /// "On"/"Off" for sharing services, "Disabled" for launch items, the state of a system extension.
    public var state: String?
    /// Who signed it ("Developer ID Application: Example Corp (ABCDE12345)"), and the team id.
    public var signer: String?
    public var teamID: String?
    public var signature: SignatureState?
    public var bundleID: String?
    /// Launch items: starts at login/boot (RunAtLoad) or is kept alive.
    public var runsAtLoad: Bool?
    /// The file's modification time: often closer to when the change happened than when FlightDeck noticed it.
    public var modified: Date?

    public init(category: ChangeCategory, key: String, name: String, version: String? = nil, scope: String? = nil, path: String? = nil,
                program: String? = nil, state: String? = nil, signer: String? = nil, teamID: String? = nil, signature: SignatureState? = nil,
                bundleID: String? = nil, runsAtLoad: Bool? = nil, modified: Date? = nil) {
        self.category = category; self.key = key; self.name = name; self.version = version; self.scope = scope; self.path = path
        self.program = program; self.state = state; self.signer = signer; self.teamID = teamID; self.signature = signature
        self.bundleID = bundleID; self.runsAtLoad = runsAtLoad; self.modified = modified
    }
}

/// Everything read in one pass. A category in `unavailable` couldn't be read this time (with the reason); its items
/// are carried over from the previous inventory so a failed read never looks like everything was removed.
public struct Inventory: Codable, Sendable {
    public var time: Date
    public var items: [InventoryItem]
    public var unavailable: [ChangeCategory: String] = [:]
    /// Parts of a category that can't be read without root or a permission (shown on the page, not errors).
    public var limits: [String] = []
    /// When the Mac last booted (a macOS update's install time is close to it).
    public var boot: Date?
    /// Whether the items include what only the root helper can read: Mac-wide profiles, and Login Items background
    /// records (read this time, or carried over while locked). nil = not included. Optional so older files decode.
    public var helperProfiles: Bool?
    public var helperBackgroundItems: Bool?
    public init(time: Date, items: [InventoryItem], unavailable: [ChangeCategory: String] = [:], limits: [String] = [], boot: Date? = nil) {
        self.time = time; self.items = items; self.unavailable = unavailable; self.limits = limits; self.boot = boot
    }
    public func items(_ c: ChangeCategory) -> [InventoryItem] { items.filter { $0.category == c } }
}

/// One difference between two inventories.
public struct ChangeEvent: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case added, removed, modified, updated
        public var title: String {
            switch self { case .added: "Added"; case .removed: "Removed"; case .modified: "Changed"; case .updated: "Updated" }
        }
    }
    public var id: String
    /// When FlightDeck noticed it (the check that found it).
    public var detected: Date
    /// A better estimate when there is one (the file's modification time, the boot after a macOS update), never later
    /// than `detected` and never before the previous check.
    public var estimated: Date?
    public var kind: Kind
    public var item: InventoryItem
    /// The item before the change (modified/updated/removed).
    public var previous: InventoryItem?
    /// One line: "Example Helper 2.1 → 2.2", "Remote Login turned on".
    public var summary: String
    /// Why it may matter, plain English ("unsigned", "runs at login from ~/Library").
    public var reasons: [String]
    public var notable: Bool

    /// The best known time of the change.
    public var when: Date { estimated ?? detected }
    public var category: ChangeCategory { item.category }

    public init(id: String, detected: Date, estimated: Date?, kind: Kind, item: InventoryItem, previous: InventoryItem?,
                summary: String, reasons: [String], notable: Bool) {
        self.id = id; self.detected = detected; self.estimated = estimated; self.kind = kind; self.item = item
        self.previous = previous; self.summary = summary; self.reasons = reasons; self.notable = notable
    }
}

/// What the page and the MCP tool show: the saved changes, the latest inventory and what couldn't be read.
public struct ChangesReport: Sendable {
    public var events: [ChangeEvent] = []
    /// When the first inventory was taken (nothing before it is known), and the latest check.
    public var baseline: Date?
    public var lastCheck: Date?
    public var inventory: Inventory?
    public init() {}
    public init(events: [ChangeEvent], baseline: Date?, lastCheck: Date?, inventory: Inventory?) {
        self.events = events; self.baseline = baseline; self.lastCheck = lastCheck; self.inventory = inventory
    }

    /// Events newest first, optionally filtered by category, notable flag and free text (name, path, team, reason).
    public func filtered(categories: Set<ChangeCategory> = [], notableOnly: Bool = false, query: String = "", since: Date? = nil) -> [ChangeEvent] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return events.filter { e in
            (categories.isEmpty || categories.contains(e.category)) && (!notableOnly || e.notable)
                && (since.map { e.when >= $0 } ?? true) && (q.isEmpty || Self.matches(e, q))
        }.sorted { $0.when > $1.when }
    }

    static func matches(_ e: ChangeEvent, _ q: String) -> Bool {
        let i = e.item
        let fields: [String?] = [i.name, i.key, i.path, i.program, i.signer, i.teamID, i.bundleID, i.version, e.summary, e.previous?.version]
        return fields.contains { $0?.lowercased().contains(q) ?? false } || e.reasons.contains { $0.lowercased().contains(q) }
    }

    /// Events grouped by local calendar day of `when`, newest day first.
    public static func byDay(_ events: [ChangeEvent], calendar: Calendar = .current) -> [(day: Date, events: [ChangeEvent])] {
        let groups = Dictionary(grouping: events) { calendar.startOfDay(for: $0.when) }
        return groups.keys.sorted(by: >).map { d in (d, groups[d]!.sorted { $0.when > $1.when }) }
    }
}
