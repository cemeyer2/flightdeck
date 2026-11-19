// Demo mode's Restarts & Crashes: two months of invented boots, a thermal shutdown, a watchdog panic, two app hangs and
// a slow login caused by an invented sync app ("CloudSyncr"). Nothing here comes from this Mac: the invented sources
// go through the real classifier and panic parser, so the page shows exactly what it would for such a history.
import Foundation
import FlightDeckCore

enum DemoRestarts {
    /// An invented panic report in the .ips form macOS writes (header line, then the JSON body).
    static func panicText(_ date: String) -> String {
        #"{"bug_type":"210","timestamp":"\#(date) -0600","os_version":"macOS 26.1 (25B78)"}"# + "\n" + #"""
        {"build" : "macOS 26.1 (25B78)", "product" : "Mac15,6", "date" : "\#(date) -0600",
         "panicString" : "panic(cpu 3 caller 0xfffffe002a1b2c3d): userspace watchdog timeout: no successful checkins from WindowServer (1 induced crashes) in 120 seconds\nservice: WindowServer, total successful checkins since wake (6120 seconds ago): 612\nPanicked task 0xfffffe1b3a8d8678: 191 pages, 8 threads: pid 104: watchdogd\n"}
        """#
    }

    static func report(now: Date = Date()) -> RestartsReport {
        let day = 86_400.0
        // A boot every 2–4 days for 60 days, at 08:xx, oldest first.
        var boots: [Date] = []
        var t = now.addingTimeInterval(-60 * day)
        var i = 0
        while t < now.addingTimeInterval(-2 * 3600) { boots.append(t); t = t.addingTimeInterval(Double(2 + i % 3) * day + Double(i % 5) * 1500); i += 1 }
        let current = now.addingTimeInterval(-2 * 3600 - 1234)
        boots.append(current)
        let thermalBoot = boots[boots.count - 6], panicBoot = boots[boots.count - 3]
        var src = BootSources()
        src.boots = boots
        // Orderly-shutdown markers a minute before every boot except the thermal shutdown and the panic.
        src.logdFlushes = boots.dropFirst().filter { $0 != thermalBoot && $0 != panicBoot }.map { $0.addingTimeInterval(-70) }
        src.logins = boots.enumerated().map { k, b in b.addingTimeInterval(b == current ? 24 : 21 + Double(k % 4) * 3) }
        src.causes = boots.dropFirst().map { b in ShutdownCauseEntry(logged: b.addingTimeInterval(9), code: b == thermalBoot ? -3 : 5) }
            .filter { $0.logged != panicBoot.addingTimeInterval(9) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS"
        let panicTime = panicBoot.addingTimeInterval(-95)
        if let p = PanicReports.parse(panicText(f.string(from: panicTime)), path: "/demo/panic-full-demo.ips", modified: panicBoot) { src.panics = [p] }
        src.power = [PowerLogEvent(time: now.addingTimeInterval(-3 * day), kind: .hibernateWake, message: "Wake from Standby [CDNVA] : due to EC.LidOpen/Lid Open Using BATT (Charge:41%)")]

        var r = RestartsReport()
        r.events = BootHistory.classify(src)
        r.panics = src.panics
        r.hibernateWakes = src.power
        r.hangs = [
            DiagnosticReport(path: "/demo/h1", kind: .hang, process: "Mail", time: now.addingTimeInterval(-5_300), summary: "lasted 95.20s"),
            DiagnosticReport(path: "/demo/h2", kind: .hang, process: "Photo Editor", time: now.addingTimeInterval(-4 * day), summary: "lasted 31.04s"),
        ]
        r.current = timing(boot: current, login: current.addingTimeInterval(24), slow: true)
        // Saved timing for earlier boots: quick until CloudSyncr arrived nine days ago.
        r.history = r.events.map { e in
            var rec = BootRecord(boot: e.boot)
            rec.verdict = e.previous
            let slow = now.timeIntervalSince(e.boot) < 9 * day
            rec.timing = e.boot == current ? r.current : e.login.map { timing(boot: e.boot, login: $0, slow: slow, variation: Double(Int(e.boot.timeIntervalSince1970) % 7)) }
            return rec
        }
        r.oldestBoot = boots.first
        r.shutdownLogSince = boots.first?.addingTimeInterval(-70)
        r.unifiedLogSince = now.addingTimeInterval(-6 * day)
        r.powerLogSince = now.addingTimeInterval(-7 * day)
        r.ssd = (cycles: 412, unsafe: 9)
        return r
    }

    /// One boot's login: CloudSyncr makes the login-items phase long and busy when `slow`.
    static func timing(boot: Date, login: Date, slow: Bool, variation: Double = 0) -> BootTiming {
        var t = BootTiming(boot: boot)
        t.loginWindow = boot.addingTimeInterval(7 + variation * 0.2)
        t.login = login
        t.desktop = login.addingTimeInterval(slow ? 41 : 12 + variation)
        let items: [(String, String, String, Double, Double)] = [
            ("CloudSyncr", "/Applications/CloudSyncr.app", "App", 6, 186),
            ("Clipboard Keeper", "/Applications/Clipboard Keeper.app", "App", 14, 3.1),
            ("MenuMeters Lite", "/Applications/MenuMeters Lite.app", "App", 15, 1.2),
            ("vendor-updater", "/Library/Application Support/Vendor/vendor-updater", "Launch agent", 18, 4.8),
            ("FlightDeck", "/Applications/FlightDeck.app", "App", 19, 2.4),
        ]
        t.items = items.filter { slow || $0.0 != "CloudSyncr" }.map { BootItem(name: $0.0, path: $0.1, kind: $0.2, startedAfterLogin: $0.3, cpuSeconds: $0.4) }
        t.itemsDone = login.addingTimeInterval(slow ? 152 : 22)
        if slow {
            t.busiest = [BootItem(name: "CloudSyncr", path: "/Applications/CloudSyncr.app", kind: "Third-party", startedAfterLogin: 6, cpuSeconds: 186),
                         BootItem(name: "mds_stores", path: "/System/Library/Frameworks/CoreServices.framework/mds_stores", kind: "macOS", startedAfterLogin: 0, cpuSeconds: 41),
                         BootItem(name: "Safari", path: "/Applications/Safari.app", kind: "macOS", startedAfterLogin: 30, cpuSeconds: 12),
                         BootItem(name: "vendor-updater", path: "/Library/Application Support/Vendor/vendor-updater", kind: "Third-party", startedAfterLogin: 18, cpuSeconds: 4.8)]
            t.busiestSource = .blackBox
        }
        return t
    }
}
