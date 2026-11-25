import Foundation
import FlightDeckHelperProtocol

// The readers' root-helper paths. Each is used only while the helper session is unlocked; any failure or refusal
// falls back to the reader's normal path, so with the helper off, locked or broken every reader behaves as before.

extension ListeningPorts {
    /// `scan()`, but with the system-wide socket table from the root helper while it is unlocked.
    public static func scan(helper: HelperSession?) -> ListeningScan {
        if let h = helper, h.state == .unlocked, case .success(.toolText(let t)) = h.request(.listeningSockets, deadline: 30),
           let s = parseHelper(t) { return s }
        return scan()
    }

    /// The helper's "#netstat" (TCP table, a "#udp" line, then the UDP table) or "#lsof" (-F) text.
    static func parseHelper(_ text: String) -> ListeningScan? {
        if text.hasPrefix("#netstat\n") {
            let parts = text.dropFirst("#netstat\n".count).components(separatedBy: "\n#udp\n")
            guard parts.count == 2, let t = parseNetstat(parts[0]), let u = parseNetstat(parts[1]) else { return nil }
            return ListeningScan(sockets: sorted(t + u), coverage: .allProcesses, viaHelper: true)
        }
        if text.hasPrefix("#lsof\n") {
            return ListeningScan(sockets: sorted(parseLsof(String(text.dropFirst("#lsof\n".count)))), coverage: .allProcesses,
                                 viaHelper: true)
        }
        return nil
    }
}

extension Connections {
    /// Every process's internet sockets from the root helper while it is unlocked; otherwise `list()` (your own
    /// processes only).
    public static func list(helper: HelperSession?) -> (items: [ConnectionItem], viaHelper: Bool) {
        if let h = helper, h.state == .unlocked, case .success(.toolText(let t)) = h.request(.internetSockets, deadline: 30) {
            return (parse(t), true)
        }
        return (list(), false)
    }
}

extension StorageBreakdownReader {
    /// `read()`, plus local snapshot sizes from the root helper while it is unlocked.
    public static func read(helper: HelperSession?) -> Result<StorageBreakdown, StorageReadError> {
        read().map { b in
            guard let h = helper, h.state == .unlocked, case .success(.snapshotSizes(let sizes)) = h.request(.snapshotSizes, deadline: 30)
            else { return b }
            return withSizes(b, sizes)
        }
    }

    /// Matches sizes to snapshots by name; a snapshot the helper didn't size keeps nil.
    static func withSizes(_ b: StorageBreakdown, _ sizes: [SnapshotSize]) -> StorageBreakdown {
        var b = b
        let byName = Dictionary(sizes.map { ($0.name, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        guard var snaps = b.snapshots, !byName.isEmpty else { return b }
        for i in snaps.indices { snaps[i].size = byName[snaps[i].name] }
        b.snapshots = snaps
        b.snapshotsViaHelper = snaps.contains { $0.size != nil }
        if snaps.allSatisfy({ $0.size != nil }) { b.snapshotNote = nil }
        return b
    }
}

extension ChangeReaders {
    /// Background item and device profile keys come from the helper only; scopes mark them for carry-over.
    static let backgroundKeyPrefix = "btm:"
    static let deviceScope = "This Mac"

    /// Mac-wide profiles and Login Items background records, while unlocked. The flags say which were read, so the
    /// matching "needs root" limit line is dropped only for what was actually read.
    static func helperItems(_ h: HelperSession) -> (items: [InventoryItem], profilesOK: Bool, itemsOK: Bool) {
        guard h.state == .unlocked else { return ([], false, false) }
        var items: [InventoryItem] = []
        var profilesOK = false, itemsOK = false
        if case .success(.profiles(let ps)) = h.request(.deviceProfiles, deadline: 30) {
            profilesOK = true
            items += ps.map { InventoryItem(category: .profile, key: "profile:" + $0.identifier, name: $0.name ?? $0.identifier, scope: deviceScope) }
        }
        if case .success(.backgroundItems(let bs)) = h.request(.backgroundItems, deadline: 30) {
            itemsOK = true
            items += backgroundItems(bs)
        }
        return (items, profilesOK, itemsOK)
    }

    /// Login Items records as launch items. Legacy agents and daemons are left out: they are the launchd plists
    /// already listed from the launchd folders.
    static func backgroundItems(_ bs: [BackgroundItem]) -> [InventoryItem] {
        var seen = Set<String>()
        return bs.compactMap { b in
            guard !b.type.hasPrefix("legacy"), b.type != "developer", b.type != "curated" else { return nil }
            guard let key = b.identifier ?? b.url ?? b.name, seen.insert(key).inserted else { return nil }
            let path = b.url.flatMap { URL(string: $0)?.path }
            return InventoryItem(category: .launchItem, key: backgroundKeyPrefix + key, name: b.name ?? key,
                                 scope: "Login Items (\(b.type))", path: path,
                                 state: b.enabled == false ? "Disabled" : nil, signer: b.developer)
        }
    }

    /// A Mac-wide profile, which only the helper reads.
    static func isHelperProfile(_ i: InventoryItem) -> Bool { i.category == .profile && i.scope == deviceScope }
    /// A Login Items background record, which only the helper reads.
    static func isBackgroundItem(_ i: InventoryItem) -> Bool { i.category == .launchItem && i.key.hasPrefix(backgroundKeyPrefix) }

    /// Adds what the helper read. When the helper is on but couldn't read (locked, failed), the previous inventory's
    /// helper-only items are carried over instead, so locking FlightDeck never reports them as removed. With the
    /// helper off (`read` nil) nothing is carried over and the inventory is exactly what the app reads itself. The
    /// inventory's helper flags record which parts are included, so the diff can tell a helper turning on or off
    /// (no events) from items really appearing or going away.
    static func addHelperItems(_ read: (items: [InventoryItem], profilesOK: Bool, itemsOK: Bool)?, to inv: inout Inventory,
                               previous: Inventory?) {
        guard let read else { return }
        let have = Set(inv.items.map(\.id))
        inv.items += read.items.filter { !have.contains($0.id) }
        let prev = previous?.items ?? []
        let have2 = Set(inv.items.map(\.id))
        if read.profilesOK {
            inv.helperProfiles = true
        } else {
            inv.items += prev.filter { isHelperProfile($0) && !have2.contains($0.id) }
            inv.helperProfiles = previous?.helperProfiles
        }
        if read.itemsOK {
            inv.helperBackgroundItems = true
        } else {
            inv.items += prev.filter { isBackgroundItem($0) && !have2.contains($0.id) }
            inv.helperBackgroundItems = previous?.helperBackgroundItems
        }
    }
}
