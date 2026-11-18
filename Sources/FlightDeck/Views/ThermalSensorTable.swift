import SwiftUI
import FlightDeckCore
// The Thermals tab's sensor list: group headers (collapsible; "Other" starts folded since it holds raw, undocumented
// sensors), one row per sensor with now/min/average/max since launch and a 5-minute sparkline, sortable columns, and a
// detail graph for the selected sensor. It replaces the old heatmap: the heat colour survives as each row's swatch.

enum SensorSortKey: String, CaseIterable { case name = "Sensor", now = "Now", min = "Min", avg = "Avg", max = "Max" }

struct SensorTable: View {
    @Environment(\.palette) var p
    let data: ThermalPageData
    @State private var sort: SensorSortKey = .name
    @State private var ascending = true
    @State private var grouped = true
    @State private var collapsed: Set<SensorGroup> = [.other]
    @State private var selected: String?
    /// Sparkline length: 75 points ≈ 5 minutes at the 4 s sensor cadence.
    static let sparkPoints = 75

    var body: some View {
        let sensors = data.catalog.sensors
        Panel(title: "Sensors", trailing: "\(sensors.count) sensors · refreshed every \(Int(PowerSampler.sensorInterval)) s · " + (data.live ? "since launch" : "replayed window")) {
            if sensors.isEmpty {
                Text("— No temperature sensors are exposed on this Mac.").foregroundStyle(p.dim)
            } else {
                if let id = selected, let s = sensors.first(where: { $0.id == id }) { SensorDetail(sensor: s, data: data) { selected = nil } }
                HStack {
                    Toggle("Group", isOn: $grouped).toggleStyle(.switch).controlSize(.small)
                    Spacer()
                    Text("Click a sensor for its history").font(.system(size: 10)).foregroundStyle(p.dim)
                }
                header
                if grouped {
                    ForEach(data.catalog.grouped, id: \.group) { g in
                        groupHeader(g.group, g.sensors)
                        if !collapsed.contains(g.group) { ForEach(sorted(g.sensors)) { row($0) } }
                    }
                } else {
                    ForEach(sorted(sensors)) { row($0) }
                }
            }
        }
    }

    func value(_ s: CatalogSensor, _ k: SensorSortKey) -> Double {
        let st = data.stats[s.id]
        switch k {
        case .name: return 0
        case .now: return s.celsius
        case .min: return st?.min ?? s.celsius
        case .avg: return st?.average ?? s.celsius
        case .max: return st?.max ?? s.celsius
        }
    }

    func sorted(_ list: [CatalogSensor]) -> [CatalogSensor] {
        guard sort != .name else { return ascending ? list : list.reversed() }   // catalog order is natural name order
        return list.sorted { ascending ? value($0, sort) < value($1, sort) : value($0, sort) > value($1, sort) }
    }

    static let cols: [(SensorSortKey, CGFloat)] = [(.now, 64), (.min, 64), (.avg, 64), (.max, 64)]

    var header: some View {
        HStack(spacing: 6) {
            sortButton(.name).frame(maxWidth: .infinity, alignment: .leading)
            Text("LAST 5 MIN").frame(width: 130, alignment: .leading)
            ForEach(Self.cols, id: \.0) { c in sortButton(c.0).frame(width: c.1, alignment: .trailing) }
        }
        .font(.meterLabel).foregroundStyle(p.dim)
    }

    func sortButton(_ k: SensorSortKey) -> some View {
        Button {
            if sort == k { ascending.toggle() } else { sort = k; ascending = k == .name }
        } label: {
            Text(k.rawValue.uppercased() + (sort == k ? (ascending ? " ▲" : " ▼") : ""))
        }.buttonStyle(.plain)
    }

    func groupHeader(_ g: SensorGroup, _ list: [CatalogSensor]) -> some View {
        let r = data.catalog.reading(for: g)
        return Button {
            if collapsed.contains(g) { collapsed.remove(g) } else { collapsed.insert(g) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed.contains(g) ? "chevron.right" : "chevron.down").frame(width: 10)
                Text(g.title.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced))
                Text("\(list.count)").foregroundStyle(p.dim)
                Spacer()
                if let r {
                    Text("avg \(Fmt.temp(r.average)) · max \(Fmt.temp(r.max))").foregroundStyle(p.dim)
                }
            }
            .font(.system(size: 11, design: .monospaced)).padding(.top, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    func row(_ s: CatalogSensor) -> some View {
        let st = data.stats[s.id]
        let isSel = selected == s.id
        return Button { selected = isSel ? nil : s.id } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(heatColor(heatFraction(s.celsius))).frame(width: 4, height: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.name).font(.system(size: 12)).lineLimit(1)
                    if s.name != s.raw {
                        Text(s.raw + (s.alsoReportedAs.map { " = " + $0 } ?? "") + (s.reference ? " · reference, not counted in maxima" : ""))
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                TempSparkline(values: data.history.series(s.id, limit: Self.sparkPoints), color: p.accent).frame(width: 130, height: 18)
                cell(s.celsius, bold: true)
                cell(st?.min); cell(st?.average); cell(st?.max)
            }
            .padding(.vertical, 2).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(isSel ? p.accent.opacity(0.15) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(s.name) (\(s.source == .smc ? "SMC key" : "HID sensor") \(s.raw))")
    }

    func cell(_ v: Double?, bold: Bool = false) -> some View {
        Text(v.map { Fmt.temp($0, digits: 1) } ?? "—")
            .font(.system(size: 12, weight: bold ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(v == nil ? p.dim : p.text)
            .frame(width: 64, alignment: .trailing)
    }
}

/// The selected sensor's history (up to 30 minutes) with its session statistics.
struct SensorDetail: View {
    @Environment(\.palette) var p
    let sensor: CatalogSensor
    let data: ThermalPageData
    let close: () -> Void
    var body: some View {
        let st = data.stats[sensor.id]
        let values = data.history.series(sensor.id)
        // Graph in the user's unit, so the scale label matches the readouts.
        let unit = TemperatureUnit.current
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(sensor.name).font(.system(size: 14, weight: .semibold))
                    Text("\(sensor.group.title) · \(sensor.source == .smc ? "SMC key" : "HID sensor") \(sensor.raw)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
                }
                Readout(label: "Now", value: Fmt.tempNumber(sensor.celsius, digits: 1), unit: unit.symbol, size: 18)
                Readout(label: "Min", value: st.map { Fmt.tempNumber($0.min, digits: 1) }, unit: unit.symbol, size: 18)
                Readout(label: "Avg", value: st.map { Fmt.tempNumber($0.average, digits: 1) }, unit: unit.symbol, size: 18)
                Readout(label: "Max", value: st.map { Fmt.tempNumber($0.max, digits: 1) }, unit: unit.symbol, size: 18)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(p.dim)
            }
            HistoryGraph(traces: [GraphTrace(name: sensor.id, values: values.map { $0.map(unit.convert) }, color: p.accent)],
                         minHeadroom: unit.convert(60), format: { String(format: "%.0f %@", $0, unit.symbol) }).frame(height: 150)
            Text("Last \(Fmt.duration(Double(values.count) * ThermalPageData.pointSeconds)) · one point per sensor read")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.background.opacity(0.5)))
    }
}

/// A small line sparkline scaled to its own min…max (with at least a 4° span, so sensor noise doesn't look like a
/// swing). nil values break the line.
struct TempSparkline: View {
    let values: [Double?]
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let v = values.compactMap { $0 }
            guard values.count > 1, let lo = v.min(), let hi = v.max() else { return }
            let span = max(hi - lo, 4), base = lo - (span - (hi - lo)) / 2
            let dx = size.width / CGFloat(values.count - 1)
            var path = Path(), pen = false
            for (i, x) in values.enumerated() {
                guard let x else { pen = false; continue }
                let pt = CGPoint(x: CGFloat(i) * dx, y: size.height * (1 - CGFloat((x - base) / span)))
                if pen { path.addLine(to: pt) } else { path.move(to: pt); pen = true }
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1.2)
        }
    }
}
