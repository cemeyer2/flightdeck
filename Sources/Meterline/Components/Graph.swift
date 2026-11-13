import SwiftUI

struct GraphTrace: Identifiable {
    var id: String { name }
    var name: String
    var values: [Double?]
    var color: Color
    var fill = true
}

/// History graph. `nil` samples break the line (gap) instead of interpolating.
struct HistoryGraph: View {
    @Environment(\.palette) var p
    var traces: [GraphTrace]
    var maxValue: Double? = nil      // nil = adaptive
    var minHeadroom: Double = 1
    var format: ((Double) -> String)? = nil
    var showGrid = true

    var scale: Double {
        if let maxValue { return maxValue }
        let m = traces.flatMap { $0.values.compactMap { $0 } }.max() ?? 0
        return niceCeil(max(m * 1.15, minHeadroom))
    }

    var body: some View {
        let top = scale
        Canvas { ctx, size in
            if showGrid {
                for i in 1..<4 {
                    let y = size.height * CGFloat(i) / 4
                    ctx.stroke(Path { $0.move(to: .init(x: 0, y: y)); $0.addLine(to: .init(x: size.width, y: y)) }, with: .color(p.grid), lineWidth: 1)
                }
                for i in 1..<12 {
                    let x = size.width * CGFloat(i) / 12
                    ctx.stroke(Path { $0.move(to: .init(x: x, y: 0)); $0.addLine(to: .init(x: x, y: size.height)) }, with: .color(p.grid.opacity(0.6)), lineWidth: 1)
                }
            }
            for t in traces {
                let n = t.values.count
                guard n > 1 else { continue }
                let dx = size.width / CGFloat(n - 1)
                // build runs of contiguous samples
                var runs: [[CGPoint]] = []; var cur: [CGPoint] = []
                for (i, v) in t.values.enumerated() {
                    if let v {
                        let y = size.height - CGFloat(min(max(v / top, 0), 1)) * size.height
                        cur.append(CGPoint(x: CGFloat(i) * dx, y: y))
                    } else if !cur.isEmpty { runs.append(cur); cur = [] }
                }
                if !cur.isEmpty { runs.append(cur) }
                for run in runs {
                    var line = Path(); line.addLines(run)
                    if t.fill, run.count > 1 {
                        var area = line
                        area.addLine(to: CGPoint(x: run.last!.x, y: size.height))
                        area.addLine(to: CGPoint(x: run.first!.x, y: size.height))
                        area.closeSubpath()
                        ctx.fill(area, with: .linearGradient(Gradient(colors: [t.color.opacity(0.35), t.color.opacity(0.03)]),
                                                             startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    }
                    if p.glow > 0 {
                        ctx.stroke(line, with: .color(t.color.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5 + p.glow * 1.5, lineJoin: .round))
                    }
                    ctx.stroke(line, with: .color(t.color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    if run.count == 1 { ctx.fill(Path(ellipseIn: CGRect(x: run[0].x - 1.5, y: run[0].y - 1.5, width: 3, height: 3)), with: .color(t.color)) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(p.background.opacity(0.6)))
        .overlay(alignment: .topLeading) {
            if let format { Text(format(top)).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim).padding(4) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    func niceCeil(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let mag = pow(10, floor(log10(v)))
        for m in [1.0, 2, 2.5, 5, 10] where m * mag >= v { return m * mag }
        return 10 * mag
    }
}

struct Legend: View {
    @Environment(\.palette) var p
    var items: [(String, Color, String)]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(item.1).frame(width: 10, height: 3)
                    Text(item.0).foregroundStyle(p.dim)
                    Text(item.2).foregroundStyle(p.text)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }
}
