// Per-app data usage (FlightDeckCore/DataUsageReport.swift): totals for today, 7 and 30 days, then one row per app
// with a 30-day sparkline, sorted by the chosen range. Apps far above their own usual day are flagged.
import SwiftUI
import FlightDeckCore

struct DataUsagePanel: View {
    @Environment(\.palette) var p
    var report: DataUsageReport?
    /// Which column the table is sorted by: 1 = today, 7, 30.
    @AppStorage("dataUsageSort") private var sortDays = 30
    @State private var showAll = false

    var body: some View {
        Panel(title: "Data usage by app", trailing: report.map { "\($0.countedDays) day\($0.countedDays == 1 ? "" : "s") counted · keeps 90" }) {
            if let r = report {
                HStack(alignment: .top, spacing: 28) {
                    Readout(label: "Today", value: r.todayTotal.map(Fmt.storage), size: 26)
                    Readout(label: "7 days", value: r.countedDays > 0 ? Fmt.storage(r.weekTotal) : nil, size: 26)
                    Readout(label: "30 days", value: r.countedDays > 0 ? Fmt.storage(r.monthTotal) : nil, size: 26)
                    Spacer(minLength: 0)
                    Picker("Sort by", selection: $sortDays) { Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30) }
                        .pickerStyle(.segmented).frame(width: 260)
                }
                Text(caption(r)).font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                if r.rows.isEmpty {
                    Text("No app traffic counted yet.").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                } else {
                    table(r)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Reading the daily log…").foregroundStyle(p.dim) }
            }
        }
    }

    func caption(_ r: DataUsageReport) -> String {
        var s = "Counted only while FlightDeck runs, from nettop's per-process byte counters (all traffic macOS attributes to each app, in + out); days it didn't run are gaps."
        if let since = r.todaySince {
            s += " Today: counting since \(since.formatted(date: .omitted, time: .shortened)), \(Fmt.duration(r.todaySeconds)) counted."
        } else {
            s += " Nothing counted today yet (per-process network data unavailable or just started)."
        }
        return s
    }

    func value(_ row: DataUsageRow) -> UInt64 { sortDays == 1 ? row.today : sortDays == 7 ? row.week : row.month }

    func table(_ r: DataUsageReport) -> some View {
        let rows = r.rows.sorted { value($0) != value($1) ? value($0) > value($1) : $0.month > $1.month }
        let shown = showAll ? rows : Array(rows.prefix(12))
        return VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("APP").gridColumnAlignment(.leading); Text("TODAY"); Text("7 DAYS"); Text("30 DAYS"); Text("IN / OUT (30 D)")
                    Text("PER DAY, 30 DAYS").gridColumnAlignment(.leading); Text("").gridColumnAlignment(.leading)
                }.font(.meterLabel).foregroundStyle(p.dim)
                ForEach(shown) { a in
                    GridRow {
                        HStack(spacing: 6) {
                            AppIcon(path: a.id.hasSuffix(".app") ? a.id + "/" : "").frame(width: 16, height: 16)
                            Text(a.name).lineLimit(1)
                        }.frame(width: 170, alignment: .leading)
                        Text(Fmt.storage(a.today)).foregroundStyle(sortDays == 1 ? p.text : p.dim)
                        Text(Fmt.storage(a.week)).foregroundStyle(sortDays == 7 ? p.text : p.dim)
                        Text(Fmt.storage(a.month)).foregroundStyle(sortDays == 30 ? p.text : p.dim)
                        Text("\(Fmt.storage(a.monthIn)) / \(Fmt.storage(a.monthOut))").foregroundStyle(p.dim)
                        DayChart(values: a.daily, labels: r.labels, style: .bars, color: a.unusual == nil ? nil : p.warn, minHeadroom: 1,
                                 format: { Fmt.storage($0) }, compact: true).frame(width: 180, height: 20)
                        // Icon + words, never colour alone.
                        if let u = a.unusual {
                            Label(u, systemImage: "exclamationmark.triangle").foregroundStyle(p.warn).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 260, alignment: .leading).help("Unusual for this app: well above its median day")
                        } else { Text("") }
                    }
                }
            }
            .font(.system(size: 11, design: .monospaced))
            if rows.count > 12 {
                Button(showAll ? "Show fewer" : "Show all \(rows.count) apps") { showAll.toggle() }.buttonStyle(.link).font(.caption)
            }
            Text("Unusual = today is at least 100 MB and over 3× the app's median day (and 200 MB above it), after 5 counted days.")
                .font(.caption).foregroundStyle(p.dim)
        }
    }
}
