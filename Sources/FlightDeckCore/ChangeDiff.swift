import Foundation

// Compares two inventories and explains each difference: what changed, when (FlightDeck's check, or the file's
// modification time when that falls between the two checks), and why it may matter. "Notable" changes are the ones a
// security tool like KnockKnock or BlockBlock would point out: unsigned or ad-hoc code set to run automatically, a
// program in a temporary or user-writable folder, a new third-party system or kernel extension, a new profile or
// managed setting, an MDM enrollment, a sharing service turned on.

public enum ChangeDiff {
    /// Every difference from `old` to `new`. Categories `old` couldn't read (or didn't have) count as their baseline:
    /// their items produce no events, so a reader that starts working never looks like a flood of additions.
    public static func diff(old: Inventory, new: Inventory, home: String = NSHomeDirectory()) -> [ChangeEvent] {
        var out: [ChangeEvent] = []
        let readBefore = Set(ChangeCategory.allCases.filter { old.unavailable[$0] == nil })
        for c in ChangeCategory.allCases where readBefore.contains(c) && new.unavailable[c] == nil {
            let a = Dictionary(old.items(c).map { ($0.key, $0) }, uniquingKeysWith: { x, _ in x })
            let b = Dictionary(new.items(c).map { ($0.key, $0) }, uniquingKeysWith: { x, _ in x })
            for (k, n) in b {
                if let o = a[k] {
                    if let e = changed(o, n, old: old, new: new, home: home) { out.append(e) }
                } else {
                    out.append(event(.added, n, nil, old: old, new: new, home: home))
                }
            }
            for (k, o) in a where b[k] == nil { out.append(event(.removed, o, o, old: old, new: new, home: home)) }
        }
        return out.sorted { $0.when > $1.when }
    }

    /// The new inventory with the items of categories it couldn't read carried over from `old`.
    public static func carryOver(old: Inventory?, new: Inventory) -> Inventory {
        guard let old else { return new }
        var n = new
        for c in new.unavailable.keys { n.items += old.items(c) }
        return n
    }

    static func changed(_ o: InventoryItem, _ n: InventoryItem, old: Inventory, new: Inventory, home: String) -> ChangeEvent? {
        if o.version != n.version, n.category != .launchItem { return event(.updated, n, o, old: old, new: new, home: home) }
        let fields: [(String?, String?)] = [(o.program, n.program), (o.state, n.state), (o.signer, n.signer), (o.teamID, n.teamID)]
        guard fields.contains(where: { $0.0 != $0.1 }) || o.runsAtLoad != n.runsAtLoad else { return nil }
        // An app's signer is only known after an update; a launch item whose program was just signature-checked for
        // the first time isn't a change either.
        if n.category == .app || (o.signer == nil && o.program == n.program && o.state == n.state && o.runsAtLoad == n.runsAtLoad) { return nil }
        return event(.modified, n, o, old: old, new: new, home: home)
    }

    public static func event(_ kind: ChangeEvent.Kind, _ item: InventoryItem, _ previous: InventoryItem?, old: Inventory, new: Inventory, home: String) -> ChangeEvent {
        let (reasons, notable) = assess(kind, item, previous, home: home)
        return ChangeEvent(id: "\(item.id)@\(Int(new.time.timeIntervalSince1970))", detected: new.time,
                           estimated: estimate(kind, item, old: old, new: new), kind: kind, item: item,
                           previous: kind == .added ? nil : previous, summary: summary(kind, item, previous), reasons: reasons, notable: notable)
    }

    /// A time between the previous check and this one that's closer to the change: the boot after a macOS update,
    /// or the item's modification time. nil when nothing better than `detected` is known (removals, out-of-range times).
    static func estimate(_ kind: ChangeEvent.Kind, _ item: InventoryItem, old: Inventory, new: Inventory) -> Date? {
        let t: Date?
        switch kind {
        case .removed: t = nil
        default: t = item.category == .macOS ? new.boot : item.modified
        }
        guard let t, t > old.time, t <= new.time else { return nil }
        return t
    }

    static func summary(_ kind: ChangeEvent.Kind, _ i: InventoryItem, _ p: InventoryItem?) -> String {
        let v = i.version.map { " \($0)" } ?? ""
        switch (i.category, kind) {
        case (.sharing, _): return "\(i.name) turned \(i.state == "On" ? "on" : "off")"
        case (.macOS, .updated): return "macOS updated: \(p?.version ?? "?") → \(i.version ?? "?")"
        case (.profile, _) where i.key.hasPrefix("enrollment:"): return "\(i.name): \(p?.state ?? "?") → \(i.state ?? "?")"
        case (_, .updated): return "\(i.name) updated: \(p?.version ?? "?") → \(i.version ?? "?")"
        case (_, .added): return "New \(i.category.noun): \(i.name)\(v)"
        case (_, .removed): return "\(i.category.noun.prefix(1).uppercased() + i.category.noun.dropFirst()) removed: \(i.name)\(v)"
        case (_, .modified):
            var what: [String] = []
            if p?.program != i.program { what.append("now runs \(i.program ?? "nothing")") }
            if p?.state != i.state { what.append(i.state.map { "now \($0.lowercased())" } ?? "now enabled") }
            if p?.signer != i.signer { what.append("signer changed") }
            if p?.runsAtLoad != i.runsAtLoad { what.append(i.runsAtLoad == true ? "now starts automatically" : "no longer starts automatically") }
            return "\(i.name) changed: " + what.joined(separator: ", ")
        }
    }
}

// MARK: Why it may matter

extension ChangeDiff {
    /// Folders anyone (or any process of the user) can write to, where persistent code is a red flag.
    static let tempPrefixes = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/Shared/", "/private/var/folders/", "/var/folders/"]

    /// Plain-English reasons, and whether the change is notable.
    public static func assess(_ kind: ChangeEvent.Kind, _ i: InventoryItem, _ p: InventoryItem?, home: String = NSHomeDirectory()) -> (reasons: [String], notable: Bool) {
        var r: [String] = [], notable = false
        guard kind != .removed else {
            if i.category == .launchItem { r.append("no longer starts automatically") }
            return (r, false)
        }
        switch i.category {
        case .launchItem:
            let user = i.path?.hasPrefix(home + "/") ?? false
            if kind == .added {
                let what = i.scope?.contains("Daemon") == true ? "new launch daemon (runs as root)" : "new launch agent"
                let when = i.runsAtLoad == true ? (i.scope?.contains("Daemon") == true ? " that runs at every boot" : " that runs at login") : ""
                r.append(what + when + (user ? " from ~/Library" : ""))
            }
            if let prog = i.program, kind == .added || p?.program != prog {
                if tempPrefixes.contains(where: prog.hasPrefix) { r.append("runs from a temporary or shared folder (\(dir(prog)))"); notable = true }
                else if prog.hasPrefix(home + "/"), !prog.hasPrefix(home + "/Applications/") {
                    r.append("runs a program in your home folder, which any app you run can modify"); notable = true
                }
                if prog.split(separator: "/").dropLast().contains(where: { $0.hasPrefix(".") }) { r.append("its program is in a hidden folder"); notable = true }
            }
            signatureReasons(i, &r, &notable)
        case .app:
            signatureReasons(i, &r, &notable)
            if kind == .added, let path = i.path, path.hasPrefix(home + "/") { r.append("installed in your home folder") }
        case .systemExtension:
            if kind == .added { r.append("new third-party system extension" + (i.teamID.map { " (team \($0))" } ?? "") + ": it runs with system privileges"); notable = true }
        case .kernelExtension:
            if kind == .added { r.append("new third-party kernel extension loaded: it runs inside the kernel"); notable = true }
        case .profile:
            if i.key.hasPrefix("enrollment:") {
                if i.state?.hasPrefix("Yes") == true { r.append("this Mac is now enrolled in device management (MDM)"); notable = true }
            } else if kind == .added {
                r.append(i.key.hasPrefix("managed:") ? "settings in this domain are now enforced by a profile" : "a new configuration profile can change settings, certificates and network traffic")
                notable = true
            }
        case .sharing:
            if i.state == "On" { r.append("other computers on the network can now connect to this Mac"); notable = true }
        case .macOS, .homebrew:
            break
        }
        return (r, notable)
    }

    static func signatureReasons(_ i: InventoryItem, _ r: inout [String], _ notable: inout Bool) {
        switch i.signature {
        case .unsigned?: r.append("unsigned (no valid code signature)"); notable = true
        case .adHoc?: r.append("ad-hoc signed (no developer identity)"); notable = true
        default: break
        }
    }

    static func dir(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
}
