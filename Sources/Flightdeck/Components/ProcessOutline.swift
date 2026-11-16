import SwiftUI
import AppKit
import FlightdeckCore

final class ProcItem: NSObject {
    var s: ProcessSample
    var children: [ProcItem] = []
    init(_ s: ProcessSample) { self.s = s }
}

enum ProcColumn: String, CaseIterable, Equatable {
    case name = "Name", pid = "PID", cpu = "CPU %", memory = "Memory", disk = "Disk", netIn = "Net In", netOut = "Net Out", energy = "Energy", wakeups = "Wakeups", threads = "Threads", user = "User"
    var width: CGFloat { switch self { case .name: 240; case .user: 90; case .cpu, .memory, .disk, .netIn, .netOut: 84; default: 62 } }
    var numeric: Bool { self != .name && self != .user }
    func key(_ s: ProcessSample) -> Double {
        switch self {
        case .pid: Double(s.pid); case .cpu: s.cpu; case .memory: Double(s.memory)
        case .disk: s.diskReadBps + s.diskWriteBps; case .energy: s.energyWatts ?? -1
        case .netIn: s.network?.inBps ?? -1; case .netOut: s.network?.outBps ?? -1
        case .wakeups: s.wakeups; case .threads: Double(s.threads); default: 0
        }
    }
    func text(_ s: ProcessSample) -> String {
        switch self {
        case .name: s.name
        case .pid: "\(s.pid)"
        case .cpu: s.restricted ? "—" : String(format: "%.1f", s.cpu)
        case .memory: s.restricted ? "—" : Fmt.bytes(s.memory)
        case .disk: s.restricted ? "—" : (s.diskReadBps + s.diskWriteBps > 0 ? Fmt.rate(s.diskReadBps + s.diskWriteBps) : "0")
        case .netIn: s.network.map { $0.inBps > 0 ? Fmt.rate($0.inBps) : "0" } ?? "—"
        case .netOut: s.network.map { $0.outBps > 0 ? Fmt.rate($0.outBps) : "0" } ?? "—"
        case .energy: s.energyWatts.map { String(format: "%.2f W", $0) } ?? "—"
        case .wakeups: s.restricted ? "—" : String(format: "%.0f", s.wakeups)
        case .threads: s.restricted ? "—" : "\(s.threads)"
        case .user: s.user
        }
    }
}

/// AppKit outline view: stable row objects, preserved expansion/selection, cheap per-second refresh.
struct ProcessOutline: NSViewRepresentable {
    var frameTime: Date?
    var processes: [ProcessSample]
    var tree: Bool
    var filter: String
    var palette: Palette
    @Binding var selection: ProcessIdentity?
    var menu: (ProcessSample) -> NSMenu
    var onOpen: ((ProcessSample) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let ov = NSOutlineView()
        ov.usesAlternatingRowBackgroundColors = true
        ov.style = .plain
        ov.intercellSpacing = NSSize(width: 6, height: 2)
        ov.rowHeight = 20
        ov.allowsMultipleSelection = false
        ov.autosaveExpandedItems = false
        ov.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for c in ProcColumn.allCases {
            let col = NSTableColumn(identifier: .init(c.rawValue))
            col.title = c.rawValue; col.width = c.width; col.minWidth = 40
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.rawValue, ascending: !c.numeric)
            if c.numeric { col.headerCell.alignment = .right }
            if c == .netIn || c == .netOut {
                col.headerToolTip = "Sampled from each process's open connections every tick (via nettop). Connections that open and close between samples aren't counted."
            }
            ov.addTableColumn(col)
            if c == .name { ov.outlineTableColumn = col }
        }
        ov.sortDescriptors = [NSSortDescriptor(key: ProcColumn.cpu.rawValue, ascending: false)]
        ov.dataSource = context.coordinator
        ov.delegate = context.coordinator
        ov.menu = NSMenu(); ov.menu?.delegate = context.coordinator
        ov.target = context.coordinator
        ov.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let sv = NSScrollView(); sv.documentView = ov; sv.hasVerticalScroller = true; sv.autohidesScrollers = true
        context.coordinator.outline = ov
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        let key = "\(frameTime?.timeIntervalSince1970 ?? 0)|\(tree)|\(filter)|\(processes.count)|\(palette.id)"
        let selChanged = c.parent.selection != selection
        c.parent = self
        if key != c.lastKey { c.lastKey = key; c.rebuild() } else if selChanged { c.applySelection() }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: ProcessOutline
        weak var outline: NSOutlineView?
        var items: [ProcessIdentity: ProcItem] = [:]
        var roots: [ProcItem] = []
        var expanded: Set<ProcessIdentity> = []
        var updating = false
        var lastKey = ""
        var lastSort: (ProcColumn, Bool) = (.cpu, false)
        init(_ p: ProcessOutline) { parent = p }

        @objc func doubleClicked(_ ov: NSOutlineView) {
            guard ov.clickedRow >= 0, let it = ov.item(atRow: ov.clickedRow) as? ProcItem else { return }
            parent.onOpen?(it.s)
        }

        func applySelection() {
            guard let ov = outline else { return }
            updating = true; defer { updating = false }
            if let sel = parent.selection, let it = items[sel] {
                let row = ov.row(forItem: it)
                if row >= 0 { ov.selectRowIndexes([row], byExtendingSelection: false); return }
            }
            ov.deselectAll(nil)
        }

        func sortKey() -> (ProcColumn, Bool) {
            let d = outline?.sortDescriptors.first
            return (ProcColumn(rawValue: d?.key ?? "") ?? .cpu, d?.ascending ?? false)
        }

        func sorted(_ a: [ProcItem]) -> [ProcItem] {
            let (col, asc) = sortKey()
            if col == .name || col == .user {
                return a.sorted { let c = col.text($0.s).localizedCaseInsensitiveCompare(col.text($1.s)); if c == .orderedSame { return $0.s.pid < $1.s.pid }; return asc ? c == .orderedAscending : c == .orderedDescending }
            }
            return a.sorted {
                let x = col.key($0.s), y = col.key($1.s)
                if x == y { return $0.s.pid < $1.s.pid }
                return asc ? x < y : x > y
            }
        }

        func rebuild() {
            guard let ov = outline else { return }
            updating = true; defer { updating = false }
            let oldRoots = roots
            var oldChildren: [ObjectIdentifier: [ProcItem]] = [:]
            for it in items.values where !it.children.isEmpty { oldChildren[ObjectIdentifier(it)] = it.children }
            var next: [ProcessIdentity: ProcItem] = [:]
            for s in parent.processes {
                let it = items[s.identity] ?? ProcItem(s)
                it.s = s; it.children = []; next[s.identity] = it
            }
            items = next
            let f = parent.filter.trimmingCharacters(in: .whitespaces).lowercased()
            if !f.isEmpty || !parent.tree {
                roots = sorted(next.values.filter { s in f.isEmpty || s.s.name.lowercased().contains(f) || "\(s.s.pid)" == f || s.s.user.lowercased() == f || s.s.path.lowercased().contains(f) })
            } else {
                let byPID = Dictionary(next.values.map { ($0.s.pid, $0) }, uniquingKeysWith: { a, _ in a })
                var r: [ProcItem] = []
                for it in next.values {
                    if it.s.pid != it.s.ppid, it.s.ppid > 1, let parentItem = byPID[it.s.ppid] { parentItem.children.append(it) } else { r.append(it) }
                }
                func sortRec(_ a: [ProcItem]) -> [ProcItem] { let s = sorted(a); s.forEach { $0.children = sortRec($0.children) }; return s }
                roots = sortRec(r)
            }
            if lastSort != sortKey() || ov.numberOfRows == 0 {
                ov.reloadData()
                for id in expanded { if let it = items[id] { ov.expandItem(it) } }
                lastSort = sortKey()
            } else {
                ov.beginUpdates()
                sync(ov, parent: nil, old: oldRoots, new: roots, oldChildren: oldChildren)
                ov.endUpdates()
                let visible = ov.rows(in: ov.visibleRect)
                if visible.length > 0 {
                    ov.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                                  columnIndexes: IndexSet(integersIn: 0..<ov.numberOfColumns))
                }
            }
            updating = false; applySelection(); updating = true
        }

        /// Applies the minimal remove/move/insert operations turning `old` into `new` under `parent`.
        func sync(_ ov: NSOutlineView, parent: ProcItem?, old: [ProcItem], new: [ProcItem], oldChildren: [ObjectIdentifier: [ProcItem]]) {
            let newSet = Set(new.map(ObjectIdentifier.init))
            let removed = IndexSet(old.indices.filter { !newSet.contains(ObjectIdentifier(old[$0])) })
            if !removed.isEmpty { ov.removeItems(at: removed, inParent: parent, withAnimation: []) }
            var cur = old.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
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
        func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? ProcItem)?.children.count ?? roots.count }
        func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? ProcItem)?.children[index] ?? roots[index] }
        func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? ProcItem)?.children.isEmpty ?? true) }
        func outlineView(_ ov: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) { rebuild() }
        func outlineViewItemDidExpand(_ n: Notification) { if !updating, let it = n.userInfo?["NSObject"] as? ProcItem { expanded.insert(it.s.identity) } }
        func outlineViewItemDidCollapse(_ n: Notification) { if !updating, let it = n.userInfo?["NSObject"] as? ProcItem { expanded.remove(it.s.identity) } }
        func outlineViewSelectionDidChange(_ n: Notification) {
            guard !updating, let ov = outline else { return }
            let it = ov.item(atRow: ov.selectedRow) as? ProcItem
            DispatchQueue.main.async { self.parent.selection = it?.s.identity }
        }

        func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
            guard let col, let c = ProcColumn(rawValue: col.identifier.rawValue), let it = item as? ProcItem else { return nil }
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            if c == .cpu {
                let v = (ov.makeView(withIdentifier: col.identifier, owner: nil) as? BarCellView) ?? BarCellView()
                v.identifier = col.identifier
                v.fraction = it.s.cpu / 100
                if v.textField?.font != font { v.textField?.font = font }
                v.textField?.stringValue = c.text(it.s)
                v.barColor = NSColor(parent.palette.level(it.s.cpu / 100))
                return v
            }
            let cell = (ov.makeView(withIdentifier: col.identifier, owner: nil) as? NSTableCellView) ?? makeCell(col.identifier, icon: c == .name)
            cell.textField?.stringValue = c.text(it.s)
            cell.textField?.font = font
            cell.textField?.alignment = c.numeric ? .right : .left
            cell.textField?.textColor = (c.text(it.s) == "—") ? .secondaryLabelColor : .labelColor
            if c == .name {
                cell.imageView?.image = icon(for: it.s.path)
                cell.toolTip = it.s.restricted ? "Owned by another user; some values are unavailable without elevated rights" : it.s.path
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
        func icon(for path: String) -> NSImage? {
            if let r = path.range(of: ".app/") { return IconCache.icon(String(path[..<r.lowerBound]) + ".app") }
            return Self.gear
        }

        // context menu
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let ov = outline, ov.clickedRow >= 0, let it = ov.item(atRow: ov.clickedRow) as? ProcItem else { return }
            let m = parent.menu(it.s)
            for i in m.items { m.removeItem(i); menu.addItem(i) }
        }
    }
}

/// CPU cell: a CALayer bar behind a right-aligned label (no custom drawing).
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

/// NSMenuItem that runs a closure.
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
