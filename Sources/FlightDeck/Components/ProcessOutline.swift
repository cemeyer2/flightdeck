// The process table on the Processes screen: an NSOutlineView wrapped for SwiftUI. AppKit is used instead of a SwiftUI
// List/Table because the table is refreshed every sample with hundreds of rows; the outline view can be updated in
// place (rows keep their objects, expansion, selection and scroll position) at a fraction of the cost.
// Three layouts: flat list (also used whenever a filter is typed), process tree (by parent PID), and app groups.
import SwiftUI
import AppKit
import FlightDeckCore

/// Reference-type row object. NSOutlineView tracks rows by object identity, so the same ProcItem is reused for a
/// process across refreshes (looked up by ProcessIdentity) and only its sample `s` is replaced.
final class ProcItem: NSObject {
    var s: ProcessSample
    var children: [ProcItem] = []
    /// App-group rows only: the group's `AppUsage` key and plain app name (not the "Name (N)" shown), for the catalog.
    var groupKey: String?
    var groupName: String?
    init(_ s: ProcessSample) { self.s = s }
}

/// Table columns. The raw value is the column identifier, header title and sort-descriptor key all at once
/// (and is persisted by column autosave), so renaming a case resets users' saved column layout.
enum ProcColumn: String, CaseIterable, Equatable {
    case name = "Name", pid = "PID", cpu = "CPU %", gpu = "GPU %", memory = "Memory", disk = "Disk", netIn = "Net In", netOut = "Net Out", energy = "Energy", wakeups = "Wakeups", threads = "Threads", kind = "Kind", sleep = "Sleep", user = "User"
    /// Initial width in points.
    var width: CGFloat { switch self { case .name: 240; case .user: 90; case .cpu, .memory, .disk, .netIn, .netOut: 84; default: 62 } }
    var hiddenByDefault: Bool { [.kind, .sleep, .threads, .wakeups].contains(self) }
    var numeric: Bool { self != .name && self != .user && self != .kind && self != .sleep }
    /// Numeric sort key. Unavailable optional values sort as -1, i.e. below every measured value (including 0).
    func key(_ s: ProcessSample) -> Double {
        switch self {
        case .pid: Double(s.pid); case .cpu: s.cpu; case .memory: Double(s.memory)
        case .disk: s.diskReadBps + s.diskWriteBps; case .energy: s.energyWatts ?? -1
        case .netIn: s.network?.inBps ?? -1; case .netOut: s.network?.outBps ?? -1
        case .wakeups: s.wakeups; case .threads: Double(s.threads); case .gpu: s.gpu ?? -1; default: 0
        }
    }
    /// Cell text. "—" means unavailable (e.g. `restricted`: owned by another user, so the sampler can't read it without
    /// root) and is drawn dimmed; a measured zero is shown as "0". Group rows (negative PIDs) show no PID.
    func text(_ s: ProcessSample) -> String {
        switch self {
        case .name: s.notResponding == true ? "\(s.name) (Not Responding)" : s.name
        case .pid: s.pid < 0 ? "" : "\(s.pid)"
        case .cpu: s.valuesUnreadable ? "—" : String(format: "%.1f", s.cpu)
        case .memory: s.valuesUnreadable ? "—" : Fmt.bytes(s.memory)
        case .disk: s.valuesUnreadable ? "—" : (s.diskReadBps + s.diskWriteBps > 0 ? Fmt.rate(s.diskReadBps + s.diskWriteBps) : "0")
        case .netIn: s.network.map { $0.inBps > 0 ? Fmt.rate($0.inBps) : "0" } ?? "—"
        case .netOut: s.network.map { $0.outBps > 0 ? Fmt.rate($0.outBps) : "0" } ?? "—"
        case .energy: s.energyWatts.map { String(format: "%.2f W", $0) } ?? "—"
        case .gpu: s.gpu.map { String(format: "%.1f", $0) } ?? ""
        case .wakeups: s.valuesUnreadable ? "—" : String(format: "%.0f", s.wakeups)
        case .threads: s.valuesUnreadable ? "—" : "\(s.threads)"
        case .user: s.user
        case .kind: s.translated == true ? "Intel" : (s.translated == false ? "Apple" : "")
        case .sleep: s.powerAssertions.map { a in a.contains { $0.preventsDisplaySleep } ? "Display" : "Prevents" } ?? ""
        }
    }
}

/// AppKit outline view: stable row objects, preserved expansion/selection, cheap per-second refresh.
/// Inputs are plain values from ProcessesView; `frameTime` (the snapshot's time) is what signals "new data".
struct ProcessOutline: NSViewRepresentable {
    var frameTime: Date?
    var processes: [ProcessSample]
    var tree: Bool
    var byApp = false
    var filter: String
    var palette: Palette
    @Binding var selection: ProcessIdentity?
    var menu: (ProcessSample) -> NSMenu
    var onOpen: ((ProcessSample) -> Void)? = nil
    /// Chrome renderers' tabs (live only), shown in the name cell and matched by the filter. Never stored.
    var tabLabels: [ProcessIdentity: ChromeTabAttribution] = [:]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let ov = NSOutlineView()
        ov.usesAlternatingRowBackgroundColors = true
        ov.style = .plain
        ov.intercellSpacing = NSSize(width: 6, height: 2)
        ov.rowHeight = 20
        ov.allowsMultipleSelection = false
        // Expansion is tracked by the coordinator by ProcessIdentity (row objects don't survive relaunch).
        ov.autosaveExpandedItems = false
        // The last column absorbs spare width; columns beyond the window scroll horizontally instead of being cut off.
        ov.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for c in ProcColumn.allCases {
            let col = NSTableColumn(identifier: .init(c.rawValue))
            col.title = c.rawValue; col.width = c.width; col.minWidth = 40
            // Numeric columns sort descending on first click (biggest first); text columns ascending.
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.rawValue, ascending: !c.numeric)
            if c.numeric { col.headerCell.alignment = .right }
            if c == .netIn || c == .netOut {
                col.headerToolTip = "Sampled from each process's open connections every tick (via nettop). Connections that open and close between samples aren't counted."
            }
            ov.addTableColumn(col)
            if c == .name { ov.outlineTableColumn = col }
        }
        ov.sortDescriptors = [NSSortDescriptor(key: ProcColumn.cpu.rawValue, ascending: false)]
        // Power users pick columns: right-click the header. Widths, order and visibility persist.
        for c in ProcColumn.allCases where c.hiddenByDefault { ov.tableColumn(withIdentifier: .init(c.rawValue))?.isHidden = true }
        ov.autosaveName = "ProcessColumns"; ov.autosaveTableColumns = true
        let headerMenu = NSMenu(); headerMenu.delegate = context.coordinator; headerMenu.identifier = .init("header")
        ov.headerView?.menu = headerMenu
        ov.dataSource = context.coordinator
        ov.delegate = context.coordinator
        // The row context menu is built on demand in menuNeedsUpdate (from the `menu` closure), for the clicked row.
        ov.menu = NSMenu(); ov.menu?.delegate = context.coordinator
        ov.target = context.coordinator
        ov.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let sv = NSScrollView(); sv.documentView = ov; sv.hasVerticalScroller = true; sv.hasHorizontalScroller = true; sv.autohidesScrollers = true
        context.coordinator.outline = ov
        return sv
    }

    /// SwiftUI calls this on every re-evaluation of ProcessesView. A rebuild only happens when the cheap `key` changes
    /// (new sample, layout mode, filter, theme); otherwise only a selection change is applied.
    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        let key = "\(frameTime?.timeIntervalSince1970 ?? 0)|\(tree)|\(byApp)|\(filter)|\(processes.count)|\(palette.id)"
        // Compares the previous binding with the new one. Both read the same underlying state, so this can be false even
        // when the selection did change; the selection is in any case re-applied at the end of every rebuild.
        // Compare with what the table last applied: both bindings point at the same state, so comparing them is always equal.
        let selChanged = c.appliedSelection != selection
        c.parent = self
        // Don't rebuild a table nobody can see (window hidden, minimised or fully covered); catch up when visible.
        let visible = sv.window?.occlusionState.contains(.visible) ?? true
        if key != c.lastKey && visible { c.lastKey = key; c.rebuild() } else if selChanged { c.applySelection() }
    }

    /// Owns the row model and acts as data source, delegate, target for double-click, and delegate of both menus.
    /// All on the main thread.
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: ProcessOutline
        weak var outline: NSOutlineView?
        /// Every row currently in the model (real processes and app group rows), by identity.
        var items: [ProcessIdentity: ProcItem] = [:]
        /// Top-level rows in display order; children hang off `ProcItem.children`.
        var roots: [ProcItem] = []
        /// User-expanded rows, by identity, so expansion survives full reloads and re-sorts. Programmatic changes are
        /// ignored via `updating`.
        var expanded: Set<ProcessIdentity> = []
        /// True while we change the outline view ourselves, so delegate callbacks don't feed back into `selection` or
        /// `expanded`.
        var updating = false
        /// See `ProcessOutline.updateNSView`.
        var lastKey = ""
        /// The selection most recently applied to (or read from) the table.
        var appliedSelection: ProcessIdentity?
        /// Sort in effect at the last rebuild; a different sort forces a full reload rather than a long series of moves.
        var lastSort: (ProcColumn, Bool) = (.cpu, false)
        init(_ p: ProcessOutline) { parent = p }

        /// Stable synthetic identities for app group rows (negative PIDs never collide with real ones).
        /// The same app always maps to the same negative PID for the coordinator's lifetime, so a group row keeps its
        /// identity (and expansion/selection) across refreshes. Start time 0 marks it as synthetic; callers check
        /// `pid > 0` before inspecting or signalling a row.
        var groupIDs: [String: Int32] = [:]
        var groupItems: [ProcessIdentity: ProcItem] = [:]
        /// Parent of every nested row at the last rebuild, to detect re-parenting.
        var lastParents: [ProcessIdentity: ProcessIdentity] = [:]
        /// Identities present at the last rebuild (to tell "moved" from "new").
        var oldIDs: Set<ProcessIdentity> = []
        func groupIdentity(_ key: String) -> ProcessIdentity {
            if groupIDs[key] == nil { groupIDs[key] = -Int32(groupIDs.count + 1) }
            return ProcessIdentity(pid: groupIDs[key]!, startTime: 0)
        }

        /// One row per app summing its processes; the processes become its children.
        /// Apps with a single process aren't grouped: the process itself becomes the root row. The group row is a copy of
        /// the first member's sample with summed metrics; optional metrics (energy, GPU, network) stay nil unless at
        /// least one member reported them, so a group never shows an invented 0. The caller sorts the result.
        func appGroups(_ all: [ProcItem]) -> [ProcItem] {
            var buckets: [String: [ProcItem]] = [:]
            var order: [String] = []
            var names: [String: String] = [:]
            for (it, gk) in zip(all, AppUsage.groupKeys(all.map(\.s))) {
                let k = gk.key
                names[k] = names[k] ?? gk.name   // from keying all processes, so restricted ones still get the app's name
                if buckets[k] == nil { order.append(k) }
                buckets[k, default: []].append(it)
            }
            return order.map { k in
                let members = buckets[k]!
                guard members.count > 1 else { return members[0] }
                var g = members[0].s
                g.identity = groupIdentity(k)
                // Note: groupKeys on a single process skips the name recovery done for the whole list, so a restricted
                // first member can give the group its process name instead of the app name.
                g.name = "\(names[k] ?? g.name) (\(members.count))"
                // A trailing slash after the bundle path lets the icon lookup (which searches for ".app/") find the app icon.
                g.path = k.hasPrefix("proc:") ? g.path : k + "/"
                g.ppid = 0
                g.cpu = members.reduce(0) { $0 + $1.s.cpu }
                g.memory = members.reduce(0) { $0 + $1.s.memory }
                g.threads = members.reduce(0) { $0 + $1.s.threads }
                g.diskReadBps = members.reduce(0) { $0 + $1.s.diskReadBps }
                g.diskWriteBps = members.reduce(0) { $0 + $1.s.diskWriteBps }
                g.wakeups = members.reduce(0) { $0 + $1.s.wakeups }
                let e = members.compactMap(\.s.energyWatts); g.energyWatts = e.isEmpty ? nil : e.reduce(0, +)
                let gp = members.compactMap(\.s.gpu); g.gpu = gp.isEmpty ? nil : gp.reduce(0, +)
                let n = members.compactMap(\.s.network)
                g.network = n.isEmpty ? nil : ProcessNetwork(inBps: n.reduce(0) { $0 + $1.inBps }, outBps: n.reduce(0) { $0 + $1.outBps },
                                                             totalIn: n.reduce(0) { $0 + $1.totalIn }, totalOut: n.reduce(0) { $0 + $1.totalOut },
                                                             connections: n.reduce(0) { $0 + $1.connections })
                g.restricted = members.allSatisfy(\.s.restricted)
                g.notResponding = members.contains { $0.s.notResponding == true } ? true : nil
                // Reuse the group's ProcItem so NSOutlineView sees the same row object.
                let item = groupItems[g.identity] ?? ProcItem(g)
                item.s = g; item.children = sorted(members); item.groupKey = k; item.groupName = names[k]
                groupItems[g.identity] = item; items[g.identity] = item
                return item
            }
        }

        static let cellFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        @objc func doubleClicked(_ ov: NSOutlineView) {
            guard ov.clickedRow >= 0, let it = ov.item(atRow: ov.clickedRow) as? ProcItem else { return }
            parent.onOpen?(it.s)
        }

        /// Mirrors `parent.selection` into the outline view (deselecting if that process is gone or not displayed).
        func applySelection() {
            appliedSelection = parent.selection
            guard let ov = outline else { return }
            updating = true; defer { updating = false }
            if let sel = parent.selection, let it = items[sel] {
                let row = ov.row(forItem: it)
                if row >= 0 { ov.selectRowIndexes([row], byExtendingSelection: false); return }
            }
            ov.deselectAll(nil)
        }

        /// Current sort column and direction from the outline view's sort descriptors (CPU descending if none).
        func sortKey() -> (ProcColumn, Bool) {
            let d = outline?.sortDescriptors.first
            return (ProcColumn(rawValue: d?.key ?? "") ?? .cpu, d?.ascending ?? false)
        }

        /// Sorts rows by the current column; ties break by PID so the order is stable between refreshes (otherwise equal
        /// rows would swap places every second).
        func sorted(_ a: [ProcItem]) -> [ProcItem] {
            let (col, asc) = sortKey()
            if !col.numeric {
                return a.sorted { let c = col.text($0.s).localizedCaseInsensitiveCompare(col.text($1.s)); if c == .orderedSame { return $0.s.pid < $1.s.pid }; return asc ? c == .orderedAscending : c == .orderedDescending }
            }
            return a.sorted {
                let x = col.key($0.s), y = col.key($1.s)
                if x == y { return $0.s.pid < $1.s.pid }
                return asc ? x < y : x > y
            }
        }

        /// Rebuilds the row model from `parent.processes` and brings the outline view up to date: a full `reloadData` when
        /// the sort changed, the table is empty, or any row changed parent; otherwise an incremental structural sync
        /// followed by a reload of the visible cells' contents.
        func rebuild() {
            guard let ov = outline else { return }
            updating = true; defer { updating = false }
            // Snapshot the old structure first: `sync` needs each item's previous children, and children are reset below.
            let oldRoots = roots
            var oldChildren: [ObjectIdentifier: [ProcItem]] = [:]
            for it in items.values where !it.children.isEmpty { oldChildren[ObjectIdentifier(it)] = it.children }
            var next: [ProcessIdentity: ProcItem] = [:]
            // Reuse each process's row object (by identity, so a recycled PID gets a new row), refresh its sample, and
            // clear its children; they are rebuilt below for the current layout.
            for s in parent.processes {
                let it = items[s.identity] ?? ProcItem(s)
                it.s = s; it.children = []; next[s.identity] = it
            }
            items = next
            // Layout: app groups (only without a filter), flat (filter typed or list mode), otherwise the process tree.
            let f = parent.filter.trimmingCharacters(in: .whitespaces).lowercased()
            if f.isEmpty && parent.byApp {
                roots = sorted(appGroups(Array(next.values)))
            } else if !f.isEmpty || !parent.tree {
                let q = ProcessQuery(f)
                let tabs = parent.tabLabels   // a renderer's text terms also match its tabs' sites and titles
                roots = sorted(next.values.filter { q.isEmpty || q.matches($0.s, extraText: tabs[$0.s.identity].map(ChromeTabText.searchText)) })
            } else {
                // Tree by parent PID. Processes whose parent is launchd (1) or the kernel, or isn't in this sample, are roots.
                // ppid is a bare PID, so parent lookup is by PID rather than identity.
                let byPID = Dictionary(next.values.map { ($0.s.pid, $0) }, uniquingKeysWith: { a, _ in a })
                var r: [ProcItem] = []
                for it in next.values {
                    // The parent must have started before the child: a parent PID that has since been reused by a newer
                    // process isn't this child's parent (the child was re-parented or orphaned).
                    if it.s.pid != it.s.ppid, it.s.ppid > 1, let parentItem = byPID[it.s.ppid],
                       parentItem.s.identity.startTime <= it.s.identity.startTime {
                        parentItem.children.append(it)
                    } else { r.append(it) }
                }
                func sortRec(_ a: [ProcItem]) -> [ProcItem] { let s = sorted(a); s.forEach { $0.children = sortRec($0.children) }; return s }
                roots = sortRec(r)
            }
            // Incremental sync (cheap: reuses cells, animates moves) assumes rows keep their parent. When any row
            // changed parent (e.g. a process joins a new app group, or is re-parented to launchd), reload instead.
            // A row counts as re-parented if (a) it had a different parent last time, (b) it was a root last time and is
            // now nested, or (c) it was nested and is now a root (or hidden) while still existing. New rows don't count.
            var parents: [ProcessIdentity: ProcessIdentity] = [:]
            func walk(_ items: [ProcItem], _ parentID: ProcessIdentity?) {
                for it in items { if let parentID { parents[it.s.identity] = parentID }; walk(it.children, it.s.identity) }
            }
            walk(roots, nil)
            let reparented = parents.contains { id, p in lastParents[id].map { $0 != p } ?? (lastParents.keys.contains(id) == false && oldIDs.contains(id)) }
                || lastParents.contains { id, _ in parents[id] == nil && next[id] != nil }
            lastParents = parents; oldIDs = Set(items.keys)
            // Forget state for processes and groups that no longer exist, so these don't grow forever.
            expanded = expanded.filter { items[$0] != nil }
            groupItems = groupItems.filter { items[$0.key] != nil }
            if lastSort != sortKey() || ov.numberOfRows == 0 || reparented {
                ov.reloadData()
                // reloadData collapses everything; restore the user's expansions (ignored by the expand callbacks while
                // `updating`, so `expanded` isn't disturbed).
                for id in expanded { if let it = items[id] { ov.expandItem(it) } }
                lastSort = sortKey()
            } else {
                // No animation: rows re-sort every second, and animated moves both overlap visually and cost a
                // full layout pass per frame. Duration 0 plus empty animation options on every insert/remove/move make the
                // changes take effect immediately.
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0; ctx.allowsImplicitAnimation = false
                    ov.beginUpdates()
                    sync(ov, parent: nil, old: oldRoots, new: roots, oldChildren: oldChildren)
                    ov.endUpdates()
                }
                // sync only fixes structure; values change every sample, so refresh the cells actually on screen.
                let visible = ov.rows(in: ov.visibleRect)
                if visible.length > 0 {
                    ov.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                                  columnIndexes: IndexSet(integersIn: 0..<ov.numberOfColumns))
                }
            }
            // applySelection sets and clears `updating` itself, so it is cleared first and set back afterwards; the defer at
            // the top then clears it for good.
            updating = false; applySelection(); updating = true
        }

        /// Applies the minimal remove/move/insert operations turning `old` into `new` under `parent`.
        /// Removals happen first (indices refer to `old`), then a single pass places each new row at its index by moving
        /// or inserting, while `cur` mirrors what the outline view now holds. Then recurses into expanded rows only:
        /// NSOutlineView hasn't loaded children of collapsed rows, so for those it's enough to reload the row when it
        /// gains or loses children (to update its disclosure triangle).
        func sync(_ ov: NSOutlineView, parent: ProcItem?, old: [ProcItem], new: [ProcItem], oldChildren: [ObjectIdentifier: [ProcItem]]) {
            let newSet = Set(new.map(ObjectIdentifier.init))
            let removed = IndexSet(old.indices.filter { !newSet.contains(ObjectIdentifier(old[$0])) })
            if !removed.isEmpty { ov.removeItems(at: removed, inParent: parent, withAnimation: []) }
            var cur = old.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
            // Note: `pos` is filled but not used below.
            var pos: [ObjectIdentifier: Int] = [:]
            for (i, it) in cur.enumerated() { pos[ObjectIdentifier(it)] = i }
            for (i, it) in new.enumerated() {
                if i < cur.count, cur[i] === it { continue }
                if let j = cur.firstIndex(where: { $0 === it }) {
                    ov.moveItem(at: j, inParent: parent, to: i, inParent: parent)
                    cur.remove(at: j); cur.insert(it, at: i)
                } else {
                    ov.insertItems(at: [i], inParent: parent, withAnimation: [])
                    cur.insert(it, at: i)
                }
            }
            for it in new {
                let was = oldChildren[ObjectIdentifier(it)] ?? []
                if ov.isItemExpanded(it) {
                    sync(ov, parent: it, old: was, new: it.children, oldChildren: oldChildren)
                } else if was.isEmpty != it.children.isEmpty {
                    ov.reloadItem(it, reloadChildren: false)
                }
            }
        }

        // data source
        // `nil` item means the root; children come straight from the model built in rebuild().
        func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? ProcItem)?.children.count ?? roots.count }
        func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? ProcItem)?.children[index] ?? roots[index] }
        func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? ProcItem)?.children.isEmpty ?? true) }
        // Clicking a column header changes the sort descriptors; rebuild immediately (a sort change forces a full reload).
        func outlineView(_ ov: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) { rebuild() }
        func outlineViewItemDidExpand(_ n: Notification) { if !updating, let it = n.userInfo?["NSObject"] as? ProcItem { expanded.insert(it.s.identity) } }
        func outlineViewItemDidCollapse(_ n: Notification) { if !updating, let it = n.userInfo?["NSObject"] as? ProcItem { expanded.remove(it.s.identity) } }
        func outlineViewSelectionDidChange(_ n: Notification) {
            guard !updating, let ov = outline else { return }
            let it = ov.item(atRow: ov.selectedRow) as? ProcItem
            // Deferred: the outline view can call this during a SwiftUI update, and writing a binding then is not allowed.
            appliedSelection = it?.s.identity   // the table already shows this; don't re-apply it on the next update
            DispatchQueue.main.async { self.parent.selection = it?.s.identity }
        }

        /// Cells are recycled via makeView(withIdentifier:); the CPU column uses a bar cell, every other column a FrameCell.
        func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
            guard let col, let c = ProcColumn(rawValue: col.identifier.rawValue), let it = item as? ProcItem else { return nil }
            let font = Self.cellFont
                // CPU is % of one core, so the bar is full at 100% (one core) or more.
            if c == .cpu {
                let v = (ov.makeView(withIdentifier: col.identifier, owner: nil) as? BarCellView) ?? BarCellView()
                v.identifier = col.identifier
                v.fraction = it.s.cpu / 100
                if v.textField?.font != font { v.textField?.font = font }
                v.textField?.stringValue = c.text(it.s)
                v.barColor = NSColor(parent.palette.level(it.s.cpu / 100))
                return v
            }
            if c == .name, it.s.pid > 0, let a = parent.tabLabels[it.s.identity], let label = ChromeTabLabel(a) {   // ChromeTabNameCell.swift
                let cell = (ov.makeView(withIdentifier: ChromeTabNameCell.reuseID, owner: nil) as? ChromeTabNameCell) ?? ChromeTabNameCell()
                cell.configure(label: label, icon: icon(for: it.s.path), font: font, tooltip: ChromeTabText.tooltip(a) + "\n" + it.s.name)
                return cell
            }
            let cell = (ov.makeView(withIdentifier: col.identifier, owner: nil) as? NSTableCellView) ?? makeCell(col.identifier, icon: c == .name)
            cell.textField?.stringValue = c.text(it.s)
            cell.textField?.font = font
            cell.textField?.alignment = c.numeric ? .right : .left
            cell.textField?.textColor = (c.text(it.s) == "—") ? .secondaryLabelColor : .labelColor
            if c == .name {
                if it.s.notResponding == true { cell.textField?.textColor = .systemRed }
                cell.imageView?.image = icon(for: it.s.path)
                // The catalog's explanation on the first line (rows never pass a signature: no I/O per row);
                // the path line says "via helper" for counters the root helper filled in.
                let match = it.groupKey.map { ProcessCatalog.shared.lookup(groupKey: $0, name: it.groupName ?? it.s.name, memberPath: it.children.first?.s.path ?? "") }
                    ?? ProcessCatalog.shared.lookup(name: it.s.name, path: it.s.path, signature: nil)
                cell.toolTip = ProcessCatalogText.rowTooltip(match, it.s)
            }
            return cell
        }

        func makeCell(_ id: NSUserInterfaceItemIdentifier, icon: Bool) -> NSTableCellView {
            let cell = FrameCell(); cell.identifier = id
            let tf = NSTextField(labelWithString: ""); tf.lineBreakMode = .byTruncatingTail
            cell.addSubview(tf); cell.textField = tf
            if icon { let iv = NSImageView(); cell.addSubview(iv); cell.imageView = iv }
            return cell
        }

        static let gear = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        /// App processes get their bundle icon (cached); everything else a gear.
        func icon(for path: String) -> NSImage? {
            if let r = path.range(of: ".app/") { return IconCache.icon(String(path[..<r.lowerBound]) + ".app") }
            return Self.gear
        }

        // context menu
        // One delegate serves two menus: the header menu (column visibility, persisted by column autosave) and the row
        // menu, which is filled for the clicked row from the SwiftUI side's `menu` closure.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu.identifier?.rawValue == "header", let ov = outline {
                let title = NSMenuItem(title: "Columns", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
                for col in ov.tableColumns where col.identifier.rawValue != ProcColumn.name.rawValue {
                    let it = ClosureMenuItem(col.title) { col.isHidden.toggle() }
                    it.state = col.isHidden ? .off : .on
                    menu.addItem(it)
                }
                return
            }
            guard let ov = outline, ov.clickedRow >= 0, let it = ov.item(atRow: ov.clickedRow) as? ProcItem else { return }
            let m = parent.menu(it.s)
            // An NSMenuItem can belong to only one menu, so items are detached from the built menu before being added.
            for i in m.items { m.removeItem(i); menu.addItem(i) }
            // A group row opens the inspector on the app's main process. Disabled in demo mode (no openInspector).
            let target = it.groupKey.map { ProcessCatalog.mainMember(groupKey: $0, it.children.map(\.s))?.identity } ?? it.s.identity
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("What Is This?", enabled: AppActions.openInspector != nil && target != nil) {
                if let target { AppActions.openInspector?(target) }
            })
        }
    }
}

/// CPU cell: a CALayer bar behind a right-aligned label (no custom drawing).
/// Implicit layer animations are disabled, so the bar jumps to its new width instead of animating on every refresh.
final class BarCellView: NSTableCellView {
    private let bar = CALayer()
    var fraction: Double = 0 { didSet { if fraction != oldValue { needsLayout = true } } }
    var barColor = NSColor.systemBlue { didSet { bar.backgroundColor = barColor.withAlphaComponent(0.30).cgColor } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bar.cornerRadius = 2
        bar.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(bar)
        let tf = NSTextField(labelWithString: ""); tf.alignment = .right
        addSubview(tf); textField = tf
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        bar.frame = CGRect(x: 0, y: 2, width: bounds.width * min(max(fraction, 0), 1), height: max(bounds.height - 4, 0))
        if let tf = textField {
            let th = tf.intrinsicContentSize.height
            tf.frame = NSRect(x: 0, y: (bounds.height - th) / 2, width: max(bounds.width - 4, 0), height: th)
        }
    }
}

/// NSMenuItem that runs a closure. The item is its own target, so it works in menus built outside a responder chain
/// (Dock menu, outline header and row menus).
final class ClosureMenuItem: NSMenuItem {
    private let action_: () -> Void
    init(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
        action_ = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self; isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { action_() }
}

/// Cell laid out with frames (no Auto Layout) for cheap per-second refresh.
/// Optional 16 pt icon at the left, then the label, both vertically centred.
final class FrameCell: NSTableCellView {
    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 2
        if let iv = imageView { iv.frame = NSRect(x: 2, y: (h - 16) / 2, width: 16, height: 16); x = 24 }
        if let tf = textField {
            let th = tf.intrinsicContentSize.height
            tf.frame = NSRect(x: x, y: (h - th) / 2, width: max(bounds.width - x - 4, 0), height: th)
        }
    }
}
