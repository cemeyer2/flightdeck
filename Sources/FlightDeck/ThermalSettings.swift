// Settings for the thermal features: per-group temperature alerts (Settings › Alerts) and the menu bar temperature
// readout (Settings › General › Menu bar), plus the text the menu bar label shows for it.
import SwiftUI
import FlightDeckCore

/// Settings › Alerts › Temperature alerts: one row per sensor family. Thresholds are stored in °C and shown in the
/// user's unit; changes are pushed to the Engine's ThermalWatch at once. Rules fire as ordinary findings, so they
/// notify (subject to "Notify for", "After it lasts", mutes and the 30-minute cooldown) and reach the Flight Log.
struct TemperatureAlertsSection: View {
    @EnvironmentObject var engine: Engine
    @AppStorage(TemperatureAlertRule.defaultsKey) private var stored = Data()
    @AppStorage(TemperatureUnit.defaultsKey) private var unitRaw = TemperatureUnit.current.rawValue

    var rules: [TemperatureAlertRule] { TemperatureAlertRule.load(stored.isEmpty ? nil : stored) }

    func update(_ i: Int, _ change: (inout TemperatureAlertRule) -> Void) {
        var r = rules; change(&r[i])
        stored = TemperatureAlertRule.save(r) ?? Data()
        engine.applyTemperatureAlerts()
    }

    var body: some View {
        let unit = TemperatureUnit(rawValue: unitRaw) ?? .celsius
        Section("Temperature alerts") {
            ForEach(Array(rules.enumerated()), id: \.element.id) { i, r in
                HStack {
                    Toggle(r.family.title, isOn: Binding(get: { r.enabled }, set: { v in update(i) { $0.enabled = v } }))
                    Spacer()
                    Text("above").foregroundStyle(.secondary)
                    // The stepper works in whole degrees of the displayed unit; the stored value is converted back to °C.
                    Stepper(value: Binding(get: { unit.convert(r.thresholdC).rounded() },
                                           set: { v in update(i) { $0.thresholdC = unit == .celsius ? v : (v - 32) * 5 / 9 } }),
                            in: unit.convert(30)...unit.convert(120), step: 1) {
                        Text(Fmt.temp(r.thresholdC)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                    Picker("for", selection: Binding(get: { r.minutes }, set: { v in update(i) { $0.minutes = v } })) {
                        Text("1 min").tag(1.0); Text("2 min").tag(2.0); Text("5 min").tag(5.0); Text("10 min").tag(10.0)
                    }.frame(width: 120)
                }
            }
            Text("The group's hottest sensor must stay above the threshold for the whole time. Alerts appear as findings and notify like any other caution.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// What the menu bar label adds after its gauges: nothing, a sensor family's hottest reading, or one sensor. Stored as
/// "" (off), "family:<group>" or "sensor:<catalog id>" in the "menuBarTemperature" default.
enum MenuBarTemperature {
    static let key = "menuBarTemperature", fanKey = "menuBarFanRPM"

    /// e.g. "CPU 72°" and/or "2400rpm"; nil when nothing is chosen. An unavailable reading shows "—", not a number.
    static func text(_ s: Snapshot?, choice: String, fan: Bool, chip: ChipFamily) -> String? {
        var parts: [String] = []
        if !choice.isEmpty {
            let catalog = s.map { SensorCatalog.build($0.power, chip: chip) }
            if choice.hasPrefix("family:"), let g = SensorGroup(rawValue: String(choice.dropFirst(7))) {
                parts.append(g.short + " " + (catalog?.reading(for: g).map { Fmt.tempNumber($0.max) + "°" } ?? "—"))
            } else if choice.hasPrefix("sensor:") {
                let id = String(choice.dropFirst(7))
                parts.append(catalog?.sensors.first { $0.id == id }.map { Fmt.tempNumber($0.celsius) + "°" } ?? "—")
            }
        }
        if fan {
            // The fastest fan; fanless Macs and unread fans show nothing rather than "0rpm".
            if let f = s?.power.fans?.max(by: { $0.rpm < $1.rpm }) { parts.append(String(format: "%.0frpm", f.rpm)) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Settings › General › Menu bar: which temperature (if any) and whether fan RPM follow the menu bar gauges.
struct MenuBarTemperatureSettings: View {
    @EnvironmentObject var engine: Engine
    @AppStorage(MenuBarTemperature.key) private var choice = ""
    @AppStorage(MenuBarTemperature.fanKey) private var fan = false
    var body: some View {
        let catalog = engine.liveSnapshot.map { SensorCatalog.build($0.power, chip: engine.thermal.chip) }
        Picker("Temperature in the menu bar", selection: $choice) {
            Text("None").tag("")
            Section("Hottest in group") {
                ForEach(catalog?.families.map(\.family) ?? [.cpu], id: \.self) { g in Text(g.title).tag("family:" + g.rawValue) }
            }
            Section("One sensor") {
                ForEach(catalog?.sensors.filter { $0.group != .other } ?? []) { s in Text("\(s.group.short) · \(s.name)").tag("sensor:" + s.id) }
            }
        }
        Toggle("Show fan speed in the menu bar", isOn: $fan)
    }
}
