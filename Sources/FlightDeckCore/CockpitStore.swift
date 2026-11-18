import Foundation
// Everything about cockpit layouts that isn't a single layout: the saved set of named layouts (and which one is shown),
// how they're loaded from user defaults (including the first run, when nothing is saved yet), the grid packing used to
// place instruments in rows, and the two small pure helpers Ambient mode uses (which gauges to show, and the burn-in
// pixel shift).

/// All of the user's cockpit layouts, stored as one JSON value in user defaults.
public struct CockpitStore: Codable, Hashable, Sendable {
    /// Format version of the JSON; bump only for a change older versions can't read.
    public var version = 1
    public var layouts: [CockpitLayout]
    /// The layout shown on the Summary page.
    public var selected: UUID
    /// The layout Ambient mode takes its gauges from; nil means the built-in "Ambient" layout (or, if the user deleted
    /// it, the standard five gauges).
    public var ambient: UUID?

    public init(layouts: [CockpitLayout], selected: UUID, ambient: UUID? = nil) {
        self.layouts = layouts; self.selected = selected; self.ambient = ambient
    }

    /// What a user with no saved layout gets: every preset, with "Default" (today's Summary page) selected.
    public static func defaults() -> CockpitStore {
        let all = CockpitLayout.presets.compactMap { CockpitLayout.makePreset($0.id) }
        return CockpitStore(layouts: all, selected: all[0].id)
    }

    /// Reads the saved JSON. No data (first run, or a user who has never edited the Summary) and unreadable data both
    /// give `defaults()`, so the page always looks like the classic Summary until the user changes it. A store that
    /// decodes but is unusable (no layouts, or a selection that no longer exists) is repaired rather than replaced.
    public static func load(_ data: Data?) -> CockpitStore {
        guard let data, var s = try? JSONDecoder().decode(CockpitStore.self, from: data) else { return defaults() }
        if s.layouts.isEmpty { return defaults() }
        if !s.layouts.contains(where: { $0.id == s.selected }) { s.selected = s.layouts[0].id }
        if let a = s.ambient, !s.layouts.contains(where: { $0.id == a }) { s.ambient = nil }
        return s
    }

    /// JSON for user defaults. Sorted keys keep the stored value stable when nothing changed.
    public func encoded() -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(self)) ?? Data()
    }

    // MARK: Access and editing

    /// The layout on the Summary page. `load` guarantees the selection exists; the fallback covers a hand-built store.
    public var current: CockpitLayout {
        get { layouts.first { $0.id == selected } ?? layouts.first ?? CockpitLayout(name: "Default", slots: []) }
        set { if let i = layouts.firstIndex(where: { $0.id == newValue.id }) { layouts[i] = newValue } }
    }

    /// Edits the selected layout in place.
    public mutating func editCurrent(_ f: (inout CockpitLayout) -> Void) {
        guard let i = layouts.firstIndex(where: { $0.id == selected }) else { return }
        f(&layouts[i])
    }

    /// Copies the selected layout under a new name (unique among the layouts) and selects the copy.
    public mutating func duplicateCurrent() {
        var copy = current
        copy.id = UUID(); copy.preset = nil
        copy.slots = copy.slots.map { InstrumentSlot($0.kind, $0.size) }   // fresh slot ids too
        copy.name = uniqueName(current.name + " Copy")
        layouts.append(copy); selected = copy.id
    }

    /// "Name", or "Name 2", "Name 3"… if that's taken.
    public func uniqueName(_ base: String) -> String {
        let names = Set(layouts.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Deletes the selected layout and selects the first remaining one. The last layout can't be deleted.
    public mutating func deleteCurrent() {
        guard layouts.count > 1 else { return }
        let gone = selected
        layouts.removeAll { $0.id == gone }
        selected = layouts[0].id
        if ambient == gone { ambient = nil }
    }

    /// The layout Ambient mode uses: the chosen one, else the built-in Ambient preset, else nil (standard gauges).
    public var ambientLayout: CockpitLayout? {
        if let a = ambient, let l = layouts.first(where: { $0.id == a }) { return l }
        return layouts.first { $0.preset == "ambient" }
    }
}

/// Places instruments in rows of equal columns, like the Summary page's original adaptive grid: as many columns of at
/// least `minColumn` points as fit, every column the same width.
public enum CockpitGrid {
    /// Column count for a width, matching SwiftUI's `GridItem(.adaptive(minimum:))`: n columns need
    /// n × minColumn + (n − 1) × spacing points. Always at least one.
    public static func columns(width: Double, minColumn: Double = 300, spacing: Double = 12) -> Int {
        max(1, Int(((width + spacing) / (minColumn + spacing)).rounded(.down)))
    }

    /// Columns an instrument spans: small one, medium two, large the whole row; never more than the row has.
    public static func span(_ size: InstrumentSize, columns: Int) -> Int {
        switch size {
        case .small: 1
        case .medium: min(2, columns)
        case .large: columns
        }
    }

    /// Where one instrument goes: its row, first column and column count.
    public struct Placement: Equatable, Sendable {
        public var row: Int, column: Int, span: Int
        public init(row: Int, column: Int, span: Int) { self.row = row; self.column = column; self.span = span }
    }

    /// Flows instruments into rows in the user's order. One that doesn't fit in what's left of a row starts the next
    /// row, leaving a gap at the end of the previous one; the order is never changed to fill gaps, so what the user
    /// dragged into place stays there.
    public static func pack(_ sizes: [InstrumentSize], columns: Int) -> [Placement] {
        let cols = max(columns, 1)
        var row = 0, col = 0
        return sizes.map { size in
            let w = span(size, columns: cols)
            if col + w > cols { row += 1; col = 0 }
            defer { col += w }
            return Placement(row: row, column: col, span: w)
        }
    }

    /// Number of rows `pack` produced.
    public static func rowCount(_ p: [Placement]) -> Int { (p.map(\.row).max() ?? -1) + 1 }
}

/// Which big gauges Ambient mode shows.
public enum AmbientPlan {
    /// Shown when the chosen layout has no gauge-type instrument (or there's no layout at all).
    public static let standard: [InstrumentKind] = [.cpu, .memory, .thermals, .energy, .network]
    /// More than this and the gauges stop being readable across a room.
    public static let maxGauges = 8

    /// The gauge-type instruments of `layout` in its order, each kind once, at most `maxGauges`; `standard` if none.
    public static func gauges(for layout: CockpitLayout?) -> [InstrumentKind] {
        var seen = Set<InstrumentKind>()
        let kinds = (layout?.slots ?? []).map(\.kind).filter { $0.isGauge && seen.insert($0).inserted }
        return kinds.isEmpty ? standard : Array(kinds.prefix(maxGauges))
    }
}

/// Burn-in protection for Ambient mode: the whole panel is nudged by one point per minute around the edge of a small
/// square, so no pixel shows the same edge for long, yet the movement is too slow to notice. It is a pure function of
/// the minute, so the view just applies it as an offset when it re-renders for a new sample: nothing animates.
public enum BurnIn {
    /// Offset (in points) for a given minute count. Walks the perimeter of a square of side 2 × `amplitude` centred on
    /// zero, one point per minute, so a full cycle takes 8 × `amplitude` minutes.
    public static func offset(minute: Int, amplitude: Int = 6) -> (x: Int, y: Int) {
        let a = max(amplitude, 1), side = 2 * a
        let t = ((minute % (4 * side)) + 4 * side) % (4 * side)   // non-negative even for negative minutes
        switch t / side {
        case 0: return (-a + t, -a)                          // top edge, left to right
        case 1: return (a, -a + (t - side))                  // right edge, downwards
        case 2: return (a - (t - 2 * side), a)               // bottom edge, right to left
        default: return (-a, a - (t - 3 * side))             // left edge, upwards
        }
    }

    /// Minutes since 1970 for `date`: the clock `offset` is driven by.
    public static func minute(of date: Date) -> Int { Int(date.timeIntervalSince1970 / 60) }
}
