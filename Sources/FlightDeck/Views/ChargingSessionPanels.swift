// Charging insights: the current charge session (curve, time to 80%/100%, holds and why charging slows above 80%)
// and battery facts with a link to the battery-health history in Trends. See ChargingSection.swift.
import SwiftUI
import FlightDeckCore

/// Charge % and charge power since plugged in, with estimates and the charging state explained.
struct ChargeSessionPanel: View {
    @Environment(\.palette) var p
    var inputs: ChargingInputs

    var body: some View {
        let b = inputs.battery
        let s = inputs.session
        Panel(title: s?.end == nil ? "This charge" : "Last charge", trailing: s.map(header)) {
            stateLine
            if let b, let est = estimates(b) {
                HStack(spacing: 28) {
                    Readout(label: "Charge", value: String(format: "%.0f", b.percent), unit: "%")
                    Readout(label: "Time to 80%", value: eta(est.to80), size: 16)
                    Readout(label: "Time to 100%", value: eta(est.toFull), size: 16)
                    Readout(label: "Basis", value: basis(est), size: 12)
                    Spacer()
                }
            }
            if let s, s.points.count >= 2 {
                // No more buckets than points, so evenly spaced samples don't leave artificial gaps between them.
                let n = min(120, s.points.count)
                let pct = s.buckets(n, now: inputs.now) { $0.percent }
                let w = s.buckets(n, now: inputs.now) { $0.batteryW.map { max($0, 0) } }
                HistoryGraph(traces: [GraphTrace(name: "pct", values: pct, color: p.accent)], maxValue: 100,
                             format: { String(format: "%.0f%%", $0) }).frame(height: 110)
                HistoryGraph(traces: [GraphTrace(name: "w", values: w, color: p.accent2)], minHeadroom: 10,
                             format: { String(format: "%.0f W", $0) }).frame(height: 70)
                Legend(items: [("Charge", p.accent, s.points.last.map { String(format: "%.0f%%", $0.percent) } ?? "—"),
                               ("Into battery", p.accent2, s.points.last?.batteryW.map { String(format: "%.1f W", max($0, 0)) } ?? "—"),
                               ("Span", p.dim, shortDuration((s.end ?? inputs.now).timeIntervalSince(s.start)))])
            } else if b?.externalConnected == true {
                Text("The charge curve builds up while FlightDeck runs on external power (kept in memory, from the samples it already takes).")
                    .font(.caption).foregroundStyle(p.dim)
            }
            Text("Above about 80% a lithium-ion battery switches from constant current to constant voltage: the current tapers as the cells approach full, so the last 20% takes about as long as the first 80%. Estimates from the recent rate don't know about that taper and read short below 80%.")
                .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The state in one sentence, with hold evidence spelled out.
    @ViewBuilder var stateLine: some View {
        switch inputs.state {
        case .noBattery: EmptyView()
        case .onBattery: Text("On battery: not charging.").foregroundStyle(p.dim)
        case .charging: Text("Charging.").foregroundStyle(p.accent)
        case .full: Text("Fully charged; the adapter is powering the Mac directly.").foregroundStyle(p.accent)
        case let .held(pct, confirms, code):
            VStack(alignment: .leading, spacing: 4) {
                Label(String(format: "Plugged in but not charging, holding at %.0f%%.", pct), systemImage: "pause.circle.fill").foregroundStyle(p.warn)
                Text("macOS pauses charging like this for Optimized Battery Charging (it learns when you usually unplug and finishes to 100% just before), for a charge limit set in Battery settings, or when the battery is too warm. Which one isn't published, and the charge-limit setting is \(notReported).")
                    .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                let ev = [confirms ? "pmset reports \"\(inputs.pmset?.state ?? "not charging")\"\(inputs.pmset?.notCharging == true ? ", not charging" : "")\(inputs.pmset?.onHold == true ? ", on hold" : "")" : nil,
                          code.map { String(format: "the charger reports not-charging reason 0x%llX (undocumented)", $0) }].compactMap { $0 }
                if !ev.isEmpty { Text("Evidence: " + ev.joined(separator: "; ") + ".").font(.caption).foregroundStyle(p.dim) }
            }
        }
    }

    func estimates(_ b: BatteryInfo) -> (to80: ChargeETA, toFull: ChargeETA)? {
        let pts = (inputs.session?.end == nil ? inputs.session?.points ?? [] : []).map { (time: $0.time, percent: $0.percent) }
        return ChargeEstimate.estimate(percent: b.percent, isCharging: b.isCharging, fullyCharged: inputs.details?.facts.fullyCharged,
                                       avgTimeToFull: inputs.details?.avgTimeToFull, timeRemaining: b.isCharging ? b.timeRemaining : nil,
                                       ratePerMinute: ChargeEstimate.rate(pts, now: inputs.now))
    }

    func eta(_ e: ChargeETA) -> String? { e.basis == .reached ? "reached" : minutesText(e.minutes) }

    /// Which source each estimate uses, e.g. "80%: recent rate · 100%: macOS estimate".
    func basis(_ e: (to80: ChargeETA, toFull: ChargeETA)) -> String {
        func one(_ x: ChargeETA) -> String { x.basis == .reached ? "reached" : x.minutes == nil ? "\(x.basis.rawValue) (not enough data yet)" : x.basis.rawValue }
        return "80%: \(one(e.to80))\n100%: \(one(e.toFull))"
    }

    func header(_ s: ChargeSessionCurve) -> String {
        let from = s.points.first.map { String(format: "from %.0f%%", $0.percent) }
        let gained = s.points.first.flatMap { f in s.points.last.map { String(format: "+%.0f%%", $0.percent - f.percent) } }
        return ([from, gained, "since \(s.start.formatted(date: .omitted, time: .shortened))"] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }
}

/// Cycle count, capacities, health, temperature, cells, condition, manufacture date; link to Trends history.
struct BatteryFactsPanel: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    var inputs: ChargingInputs

    var body: some View {
        let b = inputs.battery, f = inputs.details?.facts
        Panel(title: "Battery facts", trailing: f?.gaugeName.map { "gauge \($0)" }) {
            HStack(spacing: 28) {
                Readout(label: "Cycles", value: b?.cycleCount.map { c in f?.designCycles.map { "\(c) of \($0)" } ?? "\(c)" }, size: 16)
                Readout(label: "Design", value: (f?.designCapacity ?? b?.designCapacity).map(String.init), unit: "mAh", size: 16)
                Readout(label: "Full charge now", value: f?.fullChargeCapacity.map(String.init), unit: "mAh", size: 16)
                Readout(label: "Health", value: b?.health.map { String(format: "%.0f", $0) }, unit: "%", color: p.accent, size: 16)
                Readout(label: "Temp", value: b?.temperature.map { Fmt.tempNumber($0, digits: 1) }, unit: TemperatureUnit.current.symbol, size: 16)
                Readout(label: "Condition", value: inputs.condition, size: 16)
                Readout(label: "Made", value: f?.manufactureDate, size: 16)
                Spacer()
            }
            if let cells = f?.cellVoltages, !cells.isEmpty {
                Text("Cells: " + cells.map { String(format: "%.3f V", $0) }.joined(separator: " · ")
                     + (cells.count > 1 ? String(format: "  (spread %.0f mV)", ((cells.max() ?? 0) - (cells.min() ?? 0)) * 1000) : ""))
                    .font(.system(size: 12, design: .monospaced))
            } else {
                Text("Cell voltages: \(notReported).").font(.caption).foregroundStyle(p.dim)
            }
            Text("Health is the capacity macOS reports as Maximum Capacity (nominal ÷ design). \"Full charge now\" is the gauge's present measured full charge, which moves with temperature and recent use. \"—\" means \(notReported).")
                .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            // A tappable label rather than a Button, which off-screen renders draw as a placeholder.
            Text("Battery health history in Trends ›").font(.system(size: 12)).foregroundStyle(p.accent)
                .onTapGesture { e.navigationRequest = Destination.trends.rawValue }
        }
    }
}
