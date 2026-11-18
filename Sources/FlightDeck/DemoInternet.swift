// Demo mode's Internet page: 30 days of invented speed tests (a fast line whose responsiveness sags in the evenings,
// i.e. bufferbloat) and invented per-app data usage, with one app having an unusual day. Nothing here runs
// networkQuality or reads this Mac's traffic.
import Foundation
import FlightDeckCore

extension Demo {
    /// About three tests a day for 30 days, the newest an hour ago.
    nonisolated static func speedTests(now: Date = Date()) -> [SpeedTestResult] {
        var out: [SpeedTestResult] = []
        for k in stride(from: 90, through: 0, by: -1) {
            let t = now.addingTimeInterval(-Double(k) * 8 * 3600 - 3600)
            let hour = Calendar.current.component(.hour, from: t)
            let evening = (18...23).contains(hour)
            let wobble = 0.5 + 0.5 * sin(Double(k) / 2.7)
            var r = SpeedTestResult(time: t)
            r.downloadMbps = (evening ? 310 : 455) + 60 * wobble
            r.uploadMbps = 38 + 6 * wobble
            r.responsivenessRPM = evening ? 160 + 60 * wobble : 520 + 180 * wobble
            r.baseRTTms = 18 + 4 * wobble
            r.interface = "en0"; r.interfaceType = "wifi"; r.endpoint = "demo-edge.example"
            r.scheduled = k % 3 != 0
            var c = SpeedTestContext()
            c.wifiRSSI = -58; c.wifiNoise = -94; c.wifiTxRate = 1201; c.wifiPHY = "802.11ax (Wi-Fi 6/6E)"; c.wifiBand = "5 GHz"
            c.routerMs = 3.1; c.routerLoss = 0; c.internetMs = 17; c.internetLoss = 0
            r.context = c
            out.append(r)
        }
        // The latest one ran in the evening: Low responsiveness, so the verdict explains bufferbloat.
        if var last = out.popLast() { last.responsivenessRPM = 172; last.downloadMbps = 412; out.append(last) }
        return out
    }

    /// 30 days of per-app usage (FlightDeck "not running" on two days). Dropbox syncs a big folder today.
    nonisolated static func dataUsageDays(now: Date = Date(), calendar: Calendar = .current) -> [DayRecord] {
        let today = calendar.startOfDay(for: now)
        let gb = 1_000_000_000.0
        var out: [DayRecord] = []
        for back in stride(from: 29, through: 0, by: -1) where back != 12 && back != 13 {
            guard let start = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let w = 0.5 + 0.5 * sin(Double(back) / 2.3)
            let weekend = calendar.isDateInWeekend(start)
            func app(_ id: String, _ name: String, _ inGB: Double, _ outGB: Double) -> AppNetDay {
                AppNetDay(id: id, name: name, bytesIn: UInt64(inGB * gb), bytesOut: UInt64(outGB * gb))
            }
            var apps = [
                app("/Applications/Safari.app", "Safari", 1.1 + 0.8 * w, 0.08),
                app("/System/Applications/Music.app", "Music", 0.35 + 0.2 * w, 0.01),
                app("/Applications/zoom.us.app", "zoom.us", weekend ? 0 : 0.6 + 0.4 * w, weekend ? 0 : 0.45 + 0.3 * w),
                app("/System/Applications/Mail.app", "Mail", 0.06, 0.02),
                app("proc:softwareupdated", "softwareupdated", back == 9 ? 6.8 : 0, 0),
                app("proc:nsurlsessiond", "nsurlsessiond", 0.25 * w, 0.05),
                app("/Applications/Dropbox.app", "Dropbox", back == 0 ? 3.9 : 0.04 + 0.03 * w, back == 0 ? 0.6 : 0.02),
            ].filter { $0.total > 0 }
            apps.sort { $0.total > $1.total }
            var d = DayRecord(day: "\(back)", start: start)
            let seconds = back == 0 ? now.timeIntervalSince(start) * 0.8 : (7 + 3 * w) * 3600
            d.dataUsage = DataUsageDay(apps: apps, totalIn: apps.reduce(0) { $0 + $1.bytesIn }, totalOut: apps.reduce(0) { $0 + $1.bytesOut },
                                       countedSeconds: seconds, firstCounted: start.addingTimeInterval(back == 0 ? 7 * 3600 : 8 * 3600))
            out.append(d)
        }
        return out
    }
}
