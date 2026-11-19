// Trends destination: the 90-day daily log (FlightDeckCore/DailyLog.swift) as 7/30/90-day charts, with markers on the
// days macOS or an app changed version, a before/after comparison around a selected update, the top apps, what is
// "normal for this Mac" per app, and battery health and drain. Everything comes from the daily records; nothing here
// samples. The log is copied and prepared on a detached task when the view appears, when the range changes and every
// 5 minutes, so the per-second Engine updates don't recompute anything.
import SwiftUI
import FlightDeckCore

struct TrendsView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @AppStorage("trendsDays") private var days = 30
    @State private var data: TrendsData?
    @State private var generation = 0

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("", selection: $days) { Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    Spacer()
                    if let d = data { Text("\(d.recordedDays) day\(d.recordedDays == 1 ? "" : "s") recorded · keeps 90").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim) }
                }
                if let d = data { TrendsContent(data: d).equatable() } else { ProgressView().controlSize(.small) }
            }.padding(16)
        }
        .task(id: days) { while !Task.isCancelled { await load(); try? await Task.sleep(for: .seconds(300)) } }
    }

    func load() async {
        generation += 1
        let log = e.dailyLog, d = days, g = generation
        data = await Task.detached(priority: .utility) { TrendsData(history: log.history(), rangeDays: d, generation: g) }.value
    }
}

/// Off-screen review (UIBench): `.task` never runs before ImageRenderer captures, so build the data synchronously.
struct TrendsPreview: View {
    var log: DailyLog
    var days = 30
    var body: some View { TrendsContent(data: TrendsData(history: log.history(), rangeDays: days, generation: 0)) }
}

/// The Trends sections for prepared data. Equatable by generation, so the parent re-rendering every second (it
/// observes the Engine) doesn't redraw the charts.
struct TrendsContent: View, Equatable {
    @Environment(\.palette) var p
    let data: TrendsData
    /// The selected update's id (defaults to the newest).
    @State private var selected: String?

    static func == (a: TrendsContent, b: TrendsContent) -> Bool { a.data.generation == b.data.generation && a.data.rangeDays == b.data.rangeDays }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if data.recordedDays < 2 {
                Panel(title: "Collecting history") {
                    Text("Trends need a few days of data. FlightDeck keeps one compact record per day while it runs and has \(data.recordedDays) so far; charts fill in day by day (days it didn't run stay empty).")
                        .foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            updatesPanel
            charts
            topApps
            baselinePanel
            DrainPanelContent(status: data.charge)
            batteryHealth
        }
    }

    // MARK: Updates and before/after

    var selectedUpdate: UpdateEvent? { data.updates.first { $0.id == selected } ?? data.updates.first }

    var updatesPanel: some View {
        Panel(title: "Updates · before / after", trailing: data.updates.isEmpty ? nil : "\(data.updates.count) recorded") {
            if data.updates.isEmpty {
                Text("No macOS or app updates recorded yet. When a version changes, it's marked on the charts and compared with the days before.")
                    .foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            } else {
                // A wrapping grid rather than a horizontal scroller: many updates stay visible (and render off-screen).
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(data.updates.prefix(20)) { u in
                            Button { selected = u.id } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: u.subject == .macOS ? "apple.logo" : "app.badge")
                                    Text(u.title)
                                    Text(u.date.formatted(.dateTime.day().month(.abbreviated))).foregroundStyle(p.dim)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(u.id == selectedUpdate?.id ? p.accent.opacity(0.25) : p.background.opacity(0.6)))
                            }.buttonStyle(.plain)
                        }
                    }.font(.system(size: 11, design: .monospaced))
                if let u = selectedUpdate { comparison(Trends.compare(data.allDays, around: u)) }
            }
        }
    }

    func comparison(_ c: UpdateComparison) -> some View {
        let regressed = c.changes.contains(where: \.regression)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: regressed ? "exclamationmark.triangle.fill" : (c.needsMoreDaysAfter + c.needsMoreDaysBefore > 0 ? "hourglass" : "checkmark.circle"))
                    .foregroundStyle(regressed ? p.warn : p.dim)
                Text(c.summary).font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            if let from = c.event.from { Text("Was \(from); \(c.beforeDays) days before vs \(c.afterDays) after (the update day itself is left out).").font(.caption).foregroundStyle(p.dim) }
            if !c.changes.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow { Text("").gridColumnAlignment(.leading); Text("BEFORE"); Text("AFTER"); Text("") }.font(.meterLabel).foregroundStyle(p.dim)
                    ForEach(c.changes) { m in
                        GridRow {
                            Text(m.name)
                            Text(m.beforeText).foregroundStyle(p.dim)
                            Text(m.afterText)
                            // Status is always icon + word, never colour alone.
                            if m.regression { Label("worse", systemImage: "arrow.up.right").foregroundStyle(p.warn) }
                            else if m.improvement { Label("better", systemImage: "arrow.down.right").foregroundStyle(p.accent) }
                            else { Text(m.before == nil || m.after == nil ? "not measured" : "about the same").foregroundStyle(p.dim) }
                        }
                    }
                }.font(.system(size: 11, design: .monospaced))
            }
        }.padding(.top, 4)
    }

    // MARK: Charts

    var markerFor: Int? { selectedUpdate.flatMap { data.markerSlot[$0.id] } }

    func chart(_ title: String, _ values: [Double?], style: DayChart.Style = .line, max: Double? = nil, headroom: Double = 1,
               note: String? = nil, format: @escaping (Double) -> String) -> some View {
        Panel(title: title, trailing: note) {
            DayChart(values: values, labels: data.labels, style: style, maxValue: max, minHeadroom: headroom, format: format,
                     markers: data.markers, selectedMarker: markerFor).frame(height: 110)
        }
    }

    var charts: some View {
        let gb = 1_073_741_824.0
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                chart("Average CPU", data.series(\.cpuAverage), max: 100, format: { String(format: "%.0f%%", $0) })
                chart("Busy CPU (95th percentile)", data.series(\.cpuP95), max: 100, format: { String(format: "%.0f%%", $0) })
            }
            GridRow {
                chart("Memory pressure (average)", data.series(\.pressureAverage), max: 100, format: { String(format: "%.0f%%", $0) })
                chart("Peak swap", data.series { $0.swapMax.map { $0 / gb } }, headroom: 1, format: { String(format: "%.1f GB", $0) })
            }
            GridRow {
                chart("Energy used", data.series(\.energyWh), style: .bars, headroom: 10, note: "system, per day", format: { String(format: "%.0f Wh", $0) })
                chart("Hottest sensor", data.series(\.hottest), headroom: 50, format: { Fmt.temp($0) })
            }
            GridRow {
                chart("Crashes and hangs", data.series { d in d.crashes == nil && d.hangs == nil ? nil : Double((d.crashes ?? 0) + (d.hangs ?? 0)) },
                      style: .bars, headroom: 4, note: "macOS reports", format: { String(format: "%.0f", $0) })
                chart("Incidents", data.series { $0.incidents.map(Double.init) }, style: .bars, headroom: 4, note: "Flight Log", format: { String(format: "%.0f", $0) })
            }
            GridRow {
                chart("Asleep", data.series(\.sleepHours), style: .bars, headroom: 8, note: "hours, by wake day", format: { String(format: "%.0f h", $0) })
                chart("Time monitored", data.series { $0.observedSeconds > 0 ? $0.observedSeconds / 3600 : nil }, style: .bars, headroom: 8, note: "hours FlightDeck sampled", format: { String(format: "%.0f h", $0) })
            }
        }
    }

    // MARK: Apps

    var topApps: some View {
        Panel(title: "Top apps", trailing: "by CPU time over \(data.rangeDays) days") {
            if data.topApps.isEmpty { Text("No app usage recorded in this period yet.").foregroundStyle(p.dim) }
            ForEach(data.topApps) { a in
                HStack(spacing: 10) {
                    AppIcon(path: a.id.hasSuffix(".app") ? a.id + "/" : "").frame(width: 16, height: 16)
                    Text(a.name).lineLimit(1).frame(width: 170, alignment: .leading)
                    Text(a.version ?? "").foregroundStyle(p.dim).lineLimit(1).frame(width: 70, alignment: .leading)
                    Text(cpuTime(a.cpuSeconds)).frame(width: 80, alignment: .trailing)
                    Text(a.energyWh.map { String(format: "%.1f Wh", $0) } ?? "—").frame(width: 70, alignment: .trailing).foregroundStyle(p.dim)
                    Text(Fmt.bytes(a.peakMemory)).frame(width: 80, alignment: .trailing).foregroundStyle(p.dim)
                    DayChart(values: a.daily.map { $0.map { $0 / 3600 } }, labels: data.labels, style: .bars, minHeadroom: 0.1,
                             format: { String(format: "%.1f h CPU", $0) }, markers: data.markers, selectedMarker: markerFor, compact: true).frame(height: 22)
                }.font(.system(size: 11, design: .monospaced))
            }
            if !data.topApps.isEmpty {
                Text("CPU time · energy · peak memory over the period; bars are CPU time per day.").font(.caption).foregroundStyle(p.dim)
            }
        }
    }

    func cpuTime(_ s: Double) -> String { s >= 3600 ? String(format: "%.1f h", s / 3600) : String(format: "%.0f min", s / 60) }

    var baselinePanel: some View {
        Panel(title: "Normal for this Mac", trailing: data.baselines.isEmpty ? nil : "typical day, per app") {
            if data.baselines.isEmpty {
                // Baselines need minBaselineDays closed days with the app running for 30+ min; today doesn't count yet.
                let closedDays = max(data.allDays.filter { $0.observedSeconds > 0 }.count - (data.slots.last??.observedSeconds ?? 0 > 0 ? 1 : 0), 0)
                let need = max(data.minBaselineDays - closedDays, 1)
                Text("Needs \(need) more day\(need == 1 ? "" : "s") of data. After \(data.minBaselineDays) days FlightDeck learns each app's usual CPU and memory, and tells you when one uses far more than usual for a sustained time.")
                    .foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow { Text("APP"); Text("USUAL MEMORY"); Text("USUAL CPU"); Text("FROM") }.font(.meterLabel).foregroundStyle(p.dim)
                    ForEach(data.baselines.prefix(12)) { b in
                        GridRow {
                            Text(b.name).lineLimit(1)
                            Text("~" + Fmt.bytes(b.memory))
                            Text(String(format: "~%.0f%%", b.cpu))
                            Text("\(b.days) days").foregroundStyle(p.dim)
                        }
                    }
                }.font(.system(size: 11, design: .monospaced))
                Text("Median of each app's daily average while running. A finding appears when an app stays at 3× its usual memory (and 1 GB more) or 3× its usual CPU (and 50 points more) for 10 minutes.")
                    .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Battery

    @ViewBuilder var batteryHealth: some View {
        let health = data.series(\.batteryHealth)
        if health.contains(where: { $0 != nil }) {
            let cycles = data.slots.compactMap { $0?.cycleCount }
            Panel(title: "Battery health", trailing: cycles.last.map { "\($0) cycles" + (cycles.count > 1 ? " (+\($0 - cycles[0]) in this period)" : "") }) {
                DayChart(values: health, labels: data.labels, maxValue: 100, format: { String(format: "%.0f%%", $0) },
                         markers: data.markers, selectedMarker: markerFor).frame(height: 90)
                Text("Maximum capacity (full charge ÷ design), one point per day. The forecast to 80% and what's wearing the battery: Performance › Energy › Battery health.").font(.caption).foregroundStyle(p.dim)
            }
        }
    }
}
