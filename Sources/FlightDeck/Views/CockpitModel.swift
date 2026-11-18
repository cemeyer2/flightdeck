import SwiftUI
import FlightDeckCore
// The app side of the cockpit model: an observable wrapper around FlightDeckCore's CockpitStore that saves to user
// defaults, and the SwiftUI Layout that places instruments using CockpitGrid's packing. The layout is a plain
// `Layout` (no GeometryReader, no AppKit), so the cockpit renders off-screen for UIBench exactly as on screen.

/// The user's cockpit layouts. One shared instance backs the Summary page and Ambient mode; UIBench builds unsaved
/// ones from a hand-made store.
@MainActor
final class CockpitModel: ObservableObject {
    static let shared = CockpitModel(defaultsKey: "cockpitLayouts")

    /// Saved on every change, and only on change: a user who never edits has nothing written, so a later version's
    /// default layout still reaches them.
    @Published var store: CockpitStore {
        didSet { if store != oldValue, let k = defaultsKey { UserDefaults.standard.set(store.encoded(), forKey: k) } }
    }
    /// Edit mode on the Summary page (drag handles, remove buttons, the Add palette). Not saved.
    @Published var editing = false
    private let defaultsKey: String?

    /// Loads from `defaultsKey`; with no saved value (or an unreadable one) this is the classic Summary layout.
    init(defaultsKey: String) {
        self.defaultsKey = defaultsKey
        store = CockpitStore.load(UserDefaults.standard.data(forKey: defaultsKey))
    }

    /// An unsaved model for off-screen renders.
    init(preview: CockpitStore, editing: Bool = false) {
        defaultsKey = nil; store = preview; self.editing = editing
    }

    var current: CockpitLayout { store.current }
    func edit(_ f: (inout CockpitLayout) -> Void) { store.editCurrent(f) }
}

/// Which size an instrument was placed at, read by CockpitGridLayout from each subview.
struct InstrumentSizeKey: LayoutValueKey { static let defaultValue = InstrumentSize.small }

extension View {
    /// Tells the cockpit grid how many columns this instrument spans.
    func instrumentSize(_ s: InstrumentSize) -> some View { layoutValue(key: InstrumentSizeKey.self, value: s) }
}

/// Lays instruments out in equal columns of at least `minColumn` points (the same rule as the classic Summary's
/// adaptive grid, so the default layout looks the same), in rows packed by `CockpitGrid.pack`. Each row is as tall as
/// its tallest instrument and instruments sit at the top of their row, as cells did in the old LazyVGrid.
struct CockpitGridLayout: Layout {
    var minColumn: CGFloat = 300
    var spacing: CGFloat = 12

    /// Positions computed for one width: each subview's frame, plus the total height.
    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let cols = CockpitGrid.columns(width: Double(width), minColumn: Double(minColumn), spacing: Double(spacing))
        let colW = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        let placements = CockpitGrid.pack(subviews.map { $0[InstrumentSizeKey.self] }, columns: cols)
        func cellWidth(_ span: Int) -> CGFloat { colW * CGFloat(span) + spacing * CGFloat(span - 1) }
        // Measure every instrument at its cell width, then size each row to its tallest.
        let heights = zip(subviews, placements).map { v, pl in
            v.sizeThatFits(ProposedViewSize(width: cellWidth(pl.span), height: nil)).height
        }
        var rowH = Array(repeating: CGFloat(0), count: CockpitGrid.rowCount(placements))
        for (h, pl) in zip(heights, placements) { rowH[pl.row] = max(rowH[pl.row], h) }
        var rowY: [CGFloat] = [], y: CGFloat = 0
        for h in rowH { rowY.append(y); y += h + spacing }
        let frames = zip(heights, placements).map { h, pl in
            CGRect(x: (colW + spacing) * CGFloat(pl.column), y: rowY[pl.row], width: cellWidth(pl.span), height: h)
        }
        return (frames, max(y - spacing, 0))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // An unbounded proposal (e.g. while SwiftUI probes the ideal size) gets the width of three default columns.
        let w = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? (minColumn * 3 + spacing * 2)
        return CGSize(width: w, height: arrange(width: w, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (v, f) in zip(subviews, frames) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }
}
