// Demo mode's long-term history: 60 invented days for the Trends view (with a macOS update and a Safari update that
// made Safari hungrier and hang), and a battery session. Only ever loaded into a headless engine's in-memory
// DailyLog (`replaceForDemo` refuses a persisted one), so nothing is written.
import Foundation
import FlightDeckCore

extension Demo {
    static func trendDays(now: Date = Date(), calendar: Calendar = .current) -> [DayRecord] {
        let today = calendar.startOfDay(for: now)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        var out: [DayRecord] = []
        for back in stride(from: 60, through: 1, by: -1) {
            // A long weekend away: FlightDeck wasn't running, so those days are gaps, not zeros.
            if (34...36).contains(back) { continue }
            guard let start = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let k = Double(back)
            let wave = 0.5 + 0.5 * sin(k / 3.1)
            let newSafari = back <= 12, newOS = back <= 25
            var d = DayRecord(day: fmt.string(from: start), start: start)
            d.observedSeconds = (6 + 4 * wave) * 3600
            d.cpuAverage = 18 + 10 * wave + (newSafari ? 4 : 0); d.cpuP95 = min(d.cpuAverage! * 2.6, 100)
            d.pressureAverage = 32 + 12 * wave; d.pressureMax = d.pressureAverage! + 25
            d.swapMax = (0.5 + 1.5 * wave) * 1_073_741_824
            d.energyWh = d.observedSeconds / 3600 * (9 + 3 * wave + (newSafari ? 1.6 : 0))
            d.hottest = 62 + 14 * wave; d.worstThermalState = wave > 0.9 ? 1 : 0
            d.sleepHours = 6.5 + 1.5 * sin(k / 2.3)
            d.osVersion = newOS ? "26.1" : "26.0.1"; d.osBuild = newOS ? "25B78" : "25A362"
            d.batteryHealth = 93 - (60 - k) * 0.03; d.cycleCount = 190 + Int((60 - k) * 0.4)
            let hangs = newSafari && back % 3 == 0 ? 1 : 0
            d.hangs = hangs; d.crashes = back == 41 ? 1 : 0; d.incidents = 1 + Int(3 * wave) + hangs
            d.hangsByProcess = hangs > 0 ? ["Safari": hangs] : [:]; d.crashesByProcess = back == 41 ? ["Code Editor": 1] : [:]
            func app(_ name: String, _ path: String, cpu: Double, watts: Double, memGB: Double, hours: Double, version: String?) -> AppDay {
                var a = AppDay(id: path, name: name); a.version = version
                a.runningSeconds = hours * 3600; a.cpuSeconds = cpu / 100 * a.runningSeconds
                a.energyWh = watts * hours; a.memorySeconds = memGB * 1_073_741_824 * a.runningSeconds
                a.peakMemory = UInt64(memGB * 1.6 * 1_073_741_824)
                return a
            }
            d.apps = [
                app("Safari", "/Applications/Safari.app", cpu: newSafari ? 22 : 14, watts: newSafari ? 2.6 : 1.8, memGB: newSafari ? 3.1 : 2.2, hours: 7, version: newSafari ? "26.2" : "26.1"),
                app("Photos", "/System/Applications/Photos.app", cpu: 30 * wave + 4, watts: 3 * wave + 0.4, memGB: 1.4, hours: 2 + 3 * wave, version: "11.0"),
                app("Mail", "/System/Applications/Mail.app", cpu: 3, watts: 0.3, memGB: 0.6, hours: 9, version: "16.0"),
                app("Music", "/System/Applications/Music.app", cpu: 4, watts: 0.5, memGB: 0.5, hours: 3, version: "1.6"),
                app("mds_stores", "proc:mds_stores", cpu: 6 + 10 * wave, watts: 0.6, memGB: 0.3, hours: 10, version: nil),
                app("WindowServer", "proc:WindowServer", cpu: 12, watts: 1.0, memGB: 0.7, hours: 10, version: nil),
            ]
            out.append(d)
        }
        return out
    }

    /// On battery for 2 h 10 min: Photos and Safari used most of it.
    static func chargeStatus(now: Date = Date()) -> ChargeStatus {
        var s = ChargeSession(start: now.addingTimeInterval(-7800), sawUnplug: true, percent: 88)
        s.lastTime = now; s.lastPercent = 62; s.systemWh = 18.4
        s.apps = ["/System/Applications/Photos.app": .init(name: "Photos", icon: "/System/Applications/Photos.app", wattHours: 5.7),
                  "/Applications/Safari.app": .init(name: "Safari", icon: "/Applications/Safari.app", wattHours: 3.3),
                  "proc:WindowServer": .init(name: "WindowServer", icon: "", wattHours: 1.4),
                  "/System/Applications/Mail.app": .init(name: "Mail", icon: "/System/Applications/Mail.app", wattHours: 0.6),
                  "/System/Applications/Music.app": .init(name: "Music", icon: "/System/Applications/Music.app", wattHours: 0.5)]
        return ChargeStatus(current: s, last: nil)
    }
}
