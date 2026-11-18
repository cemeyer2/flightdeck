import SwiftUI
import FlightDeckCore
// Performance › Thermals: "why is the fan loud?", the highest temperature per group, throttling, fan health, thermal
// pressure and the full sensor list with a detail graph. All naming and logic is in core (SensorCatalog,
// ThermalWatch); this file only lays it out. The panels live in ThermalPanels.swift and the sensor list in
// ThermalSensorTable.swift.
//
// Cost: the page reads the Engine's existing samples and the ThermalWatch's bounded history; it adds no sampling of
// its own except `pmset -g therm`, which runs every 30 s only while this tab is on screen.

/// Everything the tab draws, gathered once per render. Live: the session's ThermalWatch. Replay: statistics are rebuilt
/// from the replayed frames (so they describe that moment, not this session), and fan health/throttling come from the
/// replayed snapshot alone.
struct ThermalPageData {
    let catalog: SensorCatalog
    let stats: [String: SensorStats]
    let history: SensorHistory
    let throttle: ThrottleStatus?
    let fans: [FanStatus]
    let live: Bool
    /// Seconds per history point (the sensor cadence), for axis labels.
    static let pointSeconds = PowerSampler.sensorInterval

    @MainActor init(_ e: Engine) {
        let p = e.current?.power
        if e.mode == .live {
            let st = e.thermal.status()
            catalog = p.map { SensorCatalog.build($0, chip: e.thermal.chip) } ?? st.catalog ?? SensorCatalog(chip: e.thermal.chip, sensors: [])
            history = e.thermal.history
            throttle = st.throttle
            fans = st.fans
            live = true
        } else {
            catalog = p.map { SensorCatalog.build($0, chip: e.thermal.chip) } ?? SensorCatalog(chip: e.thermal.chip, sensors: [])
            history = SensorHistory.from(frames: e.frames.compactMap { $0 }, chip: e.thermal.chip)
            throttle = nil
            fans = (p?.fans ?? []).map { f in
                FanStatus(index: f.index, rpm: f.rpm, targetRPM: f.targetRPM, minRPM: f.minRPM, maxRPM: f.maxRPM,
                          percentOfMax: f.fraction.map { $0 * 100 }, issues: [])
            }
            live = false
        }
        stats = history.allStats()
    }
}

/// Thermals tab.
struct ThermalPerf: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var body: some View {
        let pw = e.current?.power
        let data = ThermalPageData(e)
        VStack(spacing: 12) {
            // Only present when there is something to explain (fans above idle, or heat holding performance back).
            if let s = e.current, let why = FanExplainer.explain(s) { FanExplainerCard(explanation: why) }
            GroupSummaryStrip(families: data.catalog.families, stats: data.stats)
            HStack(alignment: .top, spacing: 12) {
                ThrottlePanel(status: data.throttle, snapshot: e.current)
                Panel(title: "Thermal pressure") {
                    HStack(spacing: 28) {
                        Readout(label: "State", value: pw.map { thermalName($0.thermalState) }, color: (pw?.thermalState ?? 0) >= 2 ? p.crit : p.accent)
                        Readout(label: "Hotspot", value: pw?.hottest.value.map { Fmt.tempNumber($0, digits: 1) }, unit: TemperatureUnit.current.symbol)
                        Readout(label: "Sensors", value: pw.map { _ in "\(data.catalog.sensors.count)" })
                        Spacer(minLength: 0)
                    }
                    // Four-segment meter for thermal state 0–3 (nominal, fair, serious, critical); nominal lights one segment.
                    VFDMeter(fraction: pw.map { Double($0.thermalState + 1) / 4 }, segments: 4, height: 12)
                    HistoryGraph(traces: [GraphTrace(name: "hot", values: e.series { $0.power.hottest.value }, color: p.accent)],
                                 maxValue: 110, format: { Fmt.temp($0) }).frame(height: 110)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            FanHealthPanel(fans: pw?.fans, health: data.fans)
            SensorTable(data: data)
        }
        // pmset is a process launch: only while this tab exists (it's built only when selected) and a window is on
        // screen, every 30 s. Headless engines (demo mode, UIBench) get invented limits from Demo instead.
        .task {
            guard !e.headless else { return }
            while !Task.isCancelled {
                if e.uiVisible, let l = await Task.detached(priority: .utility, operation: { ThermalLimits.read() }).value {
                    e.thermal.note(limits: l, at: Date())
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

/// "Highest by group": one chip per sensor family with its hottest reading now and its session maximum, coloured by
/// heat. Families this Mac doesn't report are left out rather than shown empty.
struct GroupSummaryStrip: View {
    @Environment(\.palette) var p
    let families: [GroupReading]
    let stats: [String: SensorStats]
    var body: some View {
        Panel(title: "Highest by group", trailing: families.isEmpty ? nil : "now · session max") {
            if families.isEmpty {
                Text("— No temperature sensors could be read on this Mac.").foregroundStyle(p.dim)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(families, id: \.family) { g in
                        let mx = stats["family:" + g.family.rawValue]?.max
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(heatColor(heatFraction(g.max))).frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(g.family.short).font(.meterLabel).foregroundStyle(p.dim)
                                Text(Fmt.temp(g.max)).font(.system(size: 16, weight: .semibold, design: .monospaced))
                                Text(mx.map { "max " + Fmt.temp($0) } ?? "max —").font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim)
                            }
                            Spacer(minLength: 0)
                        }
                        .help("\(g.family.title): hottest is \(g.hottest) (\(g.count) sensor\(g.count == 1 ? "" : "s"))")
                    }
                }
            }
        }
    }
}

/// 30 °C reads cool, 100 °C hot (the same scale the old heatmap used).
func heatFraction(_ c: Double) -> Double { min(max((c - 30) / 70, 0), 1) }
