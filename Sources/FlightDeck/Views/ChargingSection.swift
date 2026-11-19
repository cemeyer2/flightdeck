// Charging insights, a section of Performance › Energy: what the charger negotiated (USB-PD offers and the contract in
// use), the live power flow, the current charge session's curve with time-to-80%/100%, holds (Optimized Battery
// Charging / charge limit), and battery facts. Per-sample values come from `PowerSample.charging` (parsed in
// FlightDeckCore/ChargingDetails.swift from the read PowerSampler already makes); the curve from `Engine.chargeCurve`.
// Slow extras (pmset, the battery condition from system_profiler, IOPS adapter details on desktops) are fetched only
// while this section is visible. In demo mode everything shown is DemoCharging's invented session.
import SwiftUI
import FlightDeckCore
import IOKit.ps

/// Everything the charging panels show, so live, demo and off-screen renders share one view tree.
struct ChargingInputs {
    var battery: BatteryInfo?
    var details: ChargingDetails?
    var session: ChargeSessionCurve?
    var peakSystemW: Double?
    var pmset: PmsetBattery?
    /// "Good", "Service Recommended", … (system_profiler); nil until loaded or when not reported.
    var condition: String?
    /// Desktops: what IOPSCopyExternalPowerAdapterDetails reports, if anything.
    var desktopAdapter: AdapterReport?
    var now = Date()
    /// The Battery health panel's forecast and wear factors (BatteryHealthPanel.swift); nil until loaded.
    var report: BatteryReport? = nil

    var flow: ChargeFlow? { ChargeFlow.compute(battery: battery, telemetry: details?.telemetry) }
    var state: ChargeState { ChargeState.assess(battery: battery, details: details, pmset: pmset) }
}

/// The slow, on-demand readings, refreshed every 60 s while visible.
struct ChargingExtras: Sendable {
    var pmset: PmsetBattery?
    var condition: String?
    var desktopAdapter: AdapterReport?
    var report: BatteryReport?

    /// `pmset -g batt` (a process launch) runs only while plugged in and not charging, the one case where its
    /// "not charging" / "on hold" wording adds evidence. system_profiler (~1 s) runs once, for the condition.
    /// The battery report (forecast and wear) is rebuilt from the daily log on each load: O(days), no sampling.
    static func load(battery: BatteryInfo?, facts: BatteryFacts?, log: DailyLog, previous: ChargingExtras?) -> ChargingExtras {
        var x = ChargingExtras()
        if let b = battery, b.externalConnected, !b.isCharging {
            x.pmset = Shell.run("/usr/bin/pmset", ["-g", "batt"]).flatMap(PmsetBattery.parse)
        }
        if battery != nil {
            x.condition = previous?.condition ?? Shell.run("/usr/sbin/system_profiler", ["-json", "SPPowerDataType"], timeout: 20)
                .flatMap { CheckupParse.battery(Data($0.utf8))?.condition }
        } else if let d = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            let a = AdapterReport.parse(d)
            x.desktopAdapter = a.watts == nil && a.name == nil ? nil : a
        }
        let h = battery == nil ? nil : log.batteryHistory()
        x.report = BatteryReport(battery: battery, facts: facts, condition: x.condition, history: h?.days ?? [], lifetime: h?.lifetime)
        return x
    }
}

/// Live wrapper: builds inputs from the engine (or the demo session) and polls the extras.
struct ChargingSection: View {
    @EnvironmentObject var e: Engine
    @State private var extras: ChargingExtras?
    /// Off-screen renders pass inputs directly, since `.task` doesn't run before capture.
    var preview: ChargingInputs? = nil

    var body: some View {
        ChargingContent(inputs: preview ?? inputs)
            .task(id: preview == nil) {
                guard preview == nil, !Demo.isEnabled else { return }
                while !Task.isCancelled {
                    let b = e.current?.power.battery, facts = e.current?.power.charging?.facts, prev = extras, log = e.dailyLog
                    extras = await Task.detached(priority: .utility) { ChargingExtras.load(battery: b, facts: facts, log: log, previous: prev) }.value
                    try? await Task.sleep(for: .seconds(60))
                }
            }
    }

    var inputs: ChargingInputs {
        if Demo.isEnabled { return DemoCharging.inputs() }   // never real data in demo mode
        let st = e.chargeCurve.state
        return ChargingInputs(battery: e.current?.power.battery, details: e.current?.power.charging, session: st.session,
                              peakSystemW: st.peakSystemW, pmset: extras?.pmset, condition: extras?.condition,
                              desktopAdapter: extras?.desktopAdapter, report: extras?.report)
    }
}

/// The panels, top to bottom: charger, flow, this charge, battery facts. Desktops get one adapter/PSU panel.
struct ChargingContent: View {
    @Environment(\.palette) var p
    var inputs: ChargingInputs

    var body: some View {
        VStack(spacing: 12) {
            if inputs.battery == nil {
                NoBatteryPanel(adapter: inputs.desktopAdapter)
                Panel(title: "Battery health", trailing: "no battery") {
                    Text("This Mac has no battery, so there is no health to forecast or wear to measure.").foregroundStyle(p.dim)
                }
            } else {
                ChargerPanel(inputs: inputs)
                ChargeFlowPanel(inputs: inputs)
                ChargeSessionPanel(inputs: inputs)
                BatteryFactsPanel(inputs: inputs)
                BatteryHealthPanel(report: inputs.report)
            }
        }
    }
}

/// Desktop Macs: no battery, so no flow or curve; show whatever adapter/PSU facts macOS reports.
struct NoBatteryPanel: View {
    @Environment(\.palette) var p
    var adapter: AdapterReport?
    var body: some View {
        Panel(title: "Charging", trailing: "no battery") {
            Text("This Mac has no battery, so there is no charging to show. It runs from its power supply, whose draw macOS doesn't report.")
                .foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            if let a = adapter {
                HStack(spacing: 28) {
                    Readout(label: "Power supply", value: a.name ?? a.familyName, size: 16)
                    Readout(label: "Rated", value: a.watts.map(String.init), unit: "W", size: 16)
                    Readout(label: "Voltage", value: a.volts.map { String(format: "%.1f", $0) }, unit: "V", size: 16)
                    Spacer()
                }
            }
        }
    }
}

/// Shared phrasing for missing values.
let notReported = "not reported by this Mac"

/// "1 h 12 min" for minutes; "—" for nil.
func minutesText(_ m: Double?) -> String? { m.map { shortDuration(max($0, 0) * 60) } }
