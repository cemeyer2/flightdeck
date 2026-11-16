// A chart of one value per calendar day, used by the Trends view. One series per chart (one axis, no legend: the
// panel title names it). nil days are gaps: a missing bar, or a break in the line, never a drawn zero. Update days are
// drawn as thin vertical markers; hovering shows the day and its value.
import SwiftUI

struct DayChart: View {
    @Environment(\.palette) var p
    enum Style { case bars, line }
    var values: [Double?]
    /// Labels for each slot ("Mon 3 Nov"), for the hover readout and the axis.
    var labels: [String]
    var style: Style = .line
    var color: Color? = nil
    /// Fixed top of the scale; nil = adaptive.
    var maxValue: Double? = nil
    var minHeadroom: Double = 1
    var format: (Double) -> String
    /// Slot indices of update days, and the selected one (drawn stronger).
    var markers: [Int] = []
    var selectedMarker: Int? = nil
    /// Sparkline mode (table rows): no grid, scale label or date axis; hover still reads out the value.
    var compact = false
    @State private var hover: Int?

    var scale: Double {
        if let maxValue { return maxValue }
        return HistoryGraph(traces: []).niceCeil(max((values.compactMap { $0 }.max() ?? 0) * 1.15, minHeadroom))
    }

    var body: some View {
        let top = scale, n = max(values.count, 1), c = color ?? p.accent
        VStack(alignment: .leading, spacing: 2) {
            Canvas { ctx, size in
                let slot = size.width / CGFloat(n)
                func x(_ i: Int) -> CGFloat { slot * (CGFloat(i) + 0.5) }
                func y(_ v: Double) -> CGFloat { size.height - CGFloat(min(max(v / top, 0), 1)) * size.height }
                for i in 1..<4 where !compact {   // recessive grid
                    let gy = size.height * CGFloat(i) / 4
                    ctx.stroke(Path { $0.move(to: .init(x: 0, y: gy)); $0.addLine(to: .init(x: size.width, y: gy)) }, with: .color(p.grid), lineWidth: 1)
                }
                for m in markers where m < n {
                    let strong = m == selectedMarker
                    ctx.stroke(Path { $0.move(to: .init(x: x(m), y: 0)); $0.addLine(to: .init(x: x(m), y: size.height)) },
                               with: .color(strong ? p.warn : p.dim.opacity(0.6)), style: StrokeStyle(lineWidth: strong ? 2 : 1, dash: strong ? [] : [3, 3]))
                }
                switch style {
                case .bars:
                    // Thin bars with a gap between neighbours; rounded top, anchored to the baseline.
                    let w = max(min(slot - 2, 14), 1)
                    for (i, v) in values.enumerated() {
                        guard let v else { continue }
                        let r = CGRect(x: x(i) - w / 2, y: y(v), width: w, height: size.height - y(v))
                        ctx.fill(Path(roundedRect: r, cornerSize: CGSize(width: min(2, w / 2), height: min(2, w / 2))), with: .color(i == hover ? c : c.opacity(0.8)))
                    }
                case .line:
                    var run: [CGPoint] = []
                    func flush() {
                        if run.count > 1 { var l = Path(); l.addLines(run); ctx.stroke(l, with: .color(c), style: StrokeStyle(lineWidth: 2, lineJoin: .round)) }
                        // An isolated day (gaps both sides) is a dot, so it isn't invisible.
                        if run.count == 1 { ctx.fill(Path(ellipseIn: CGRect(x: run[0].x - 2.5, y: run[0].y - 2.5, width: 5, height: 5)), with: .color(c)) }
                        run = []
                    }
                    for (i, v) in values.enumerated() { if let v { run.append(CGPoint(x: x(i), y: y(v))) } else { flush() } }
                    flush()
                }
                if let h = hover, h < n {
                    ctx.stroke(Path { $0.move(to: .init(x: x(h), y: 0)); $0.addLine(to: .init(x: x(h), y: size.height)) }, with: .color(p.text.opacity(0.35)), lineWidth: 1)
                    if style == .line, let v = values[h] { ctx.fill(Path(ellipseIn: CGRect(x: x(h) - 4, y: y(v) - 4, width: 8, height: 8)), with: .color(c)) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(p.background.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Nothing measured in the range: say so, rather than leaving an empty plot that reads as zero.
            .overlay { if !compact && values.allSatisfy({ $0 == nil }) { Text("no data yet").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim) } }
            .overlay(alignment: .topLeading) { if !compact { Text(format(top)).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim).padding(4) } }
            .overlay(alignment: .topTrailing) {
                if let h = hover, h < labels.count {
                    Text("\(labels[h]): \(values[h].map(format) ?? "no data")")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.text)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(p.panel)).padding(4)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt): hover = nil; hoverAt(pt.x)
                case .ended: hover = nil
                }
            }
            .background(GeometryReader { g in Color.clear.preference(key: ChartWidthKey.self, value: g.size.width) })
            .onPreferenceChange(ChartWidthKey.self) { width = $0 }
            // Axis: first, middle and last day.
            if !compact { HStack {
                Text(labels.first ?? ""); Spacer(); Text(labels.count > 2 ? labels[labels.count / 2] : ""); Spacer(); Text(labels.last ?? "")
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim) }
        }
    }

    @State private var width: CGFloat = 1
    private func hoverAt(_ px: CGFloat) {
        let i = Int(px / max(width, 1) * CGFloat(values.count))
        hover = (0..<values.count).contains(i) ? i : nil
    }
}

private struct ChartWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
