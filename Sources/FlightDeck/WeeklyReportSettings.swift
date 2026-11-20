// Weekly Report settings (Settings › Alerts): the opt-in weekly notification, its day and time. Kept here so the
// shared Settings form gains a single line.
import SwiftUI
import FlightDeckCore

struct WeeklyReportSettingsSection: View {
    @AppStorage(WeeklySchedule.enabledKey) private var enabled = false
    @AppStorage(WeeklySchedule.weekdayKey) private var weekday = WeeklySchedule.defaultWeekday
    @AppStorage(WeeklySchedule.minutesKey) private var minutes = WeeklySchedule.defaultMinutes

    var body: some View {
        Section("Weekly Report") {
            Toggle("Notify me with a weekly summary", isOn: $enabled)
                .onChange(of: enabled) { WeeklyReportService.scheduleChanged(); if enabled { Alerts.shared.requestPermission() } }
            Picker("Day", selection: $weekday) {
                // Calendar weekdays: 1 = Sunday … 7 = Saturday; listed from Monday.
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { d in Text(Calendar.current.weekdaySymbols[d - 1]).tag(d) }
            }.disabled(!enabled).onChange(of: weekday) { WeeklyReportService.scheduleChanged() }
            DatePicker("Time", selection: Binding(get: {
                Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minutes) * 60)
            }, set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                minutes = (c.hour ?? 9) * 60 + (c.minute ?? 0)
            }), displayedComponents: .hourAndMinute).disabled(!enabled)
                .onChange(of: minutes) { WeeklyReportService.scheduleChanged() }
            Text("Summarizes the week that just ended (Monday to Sunday) and opens the Weekly Report when clicked. If the Mac is asleep or FlightDeck isn't running then, it arrives at the next wake or launch.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(Demo.isEnabled)
    }
}
