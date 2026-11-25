// Demo mode for README screenshots: `open FlightDeck.app --args -demo YES` runs the real UI on a fabricated "Demo Mac".
// Nothing shown comes from this machine: every value a view shows (apps, users, paths, sizes, findings, incidents,
// reports, rules, sleep history, chip name, core layout) is overwritten with invented data. A real sample is only used as
// a structural template, because the core library's sample types can't be constructed outside it. Views that unavoidably
// read live machine facts (GPU model, displays, the process inspector, routes/DNS, System Info, Disk Space) are not
// covered and shouldn't be screenshotted. Demo mode never saves rules, never alerts, and can't act on real processes.
import SwiftUI
import AppKit
import FlightDeckCore

@MainActor
enum Demo {
    /// One invented app and the processes it runs.
    struct App {
        var name: String, path: String, cpu: Double, memGB: Double, procs: Int
        var gpu: Double? = nil, watts: Double = 0.2, diskMB: Double = 0, netKB: Double = 0, hung = false, wakeups: Double = 2
    }

    /// A busy afternoon: Photos exporting, Spotlight indexing, Safari with many tabs, Mail stuck.
    static let apps: [App] = [
        App(name: "Photos", path: "/System/Applications/Photos.app/Contents/MacOS/Photos", cpu: 165, memGB: 2.1, procs: 3, gpu: 38, watts: 7.8, diskMB: 18),
        App(name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", cpu: 46, memGB: 5.8, procs: 14, gpu: 9, watts: 3.1, netKB: 2400, wakeups: 140),
        App(name: "mds_stores", path: "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds_stores", cpu: 62, memGB: 0.4, procs: 1, watts: 1.6, diskMB: 132),
        App(name: "Music", path: "/System/Applications/Music.app/Contents/MacOS/Music", cpu: 9, memGB: 0.6, procs: 2, gpu: 2, watts: 0.6, netKB: 320),
        App(name: "Mail", path: "/System/Applications/Mail.app/Contents/MacOS/Mail", cpu: 31, memGB: 1.2, procs: 2, watts: 0.9, hung: true),
        App(name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", cpu: 18, memGB: 0.7, procs: 1, gpu: 21, watts: 1.1),
        App(name: "Notes", path: "/System/Applications/Notes.app/Contents/MacOS/Notes", cpu: 2, memGB: 0.3, procs: 1),
        App(name: "Messages", path: "/System/Applications/Messages.app/Contents/MacOS/Messages", cpu: 3, memGB: 0.4, procs: 2, netKB: 40),
        App(name: "kernel_task", path: "", cpu: 14, memGB: 0.1, procs: 1),
        App(name: "Google Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", cpu: 38, memGB: 2.4, procs: 5, gpu: 4, watts: 1.8, netKB: 600),   // tabs: DemoChromeTabs
    ]

    /// Frames for the last minute, 1 s apart, with gentle variation so graphs look alive.
    static func frames(template: Snapshot, count: Int = 90) -> [Snapshot] {
        let now = Date()
        return (0..<count).map { frame(template: template, i: $0, time: now.addingTimeInterval(Double($0 - count + 1))) }
    }

    /// Frame number `i` of the demo stream. Variation mixes two sines and a deterministic jitter so graphs look organic.
    static func frame(template: Snapshot, i: Int, time: Date) -> Snapshot {
        do {
            let t = Double(i)
            var s = template
            s.time = time
            let jitter = { (seed: Double) in sin(t * 12.9898 + seed * 78.233) * 43758.5453 - floor(sin(t * 12.9898 + seed * 78.233) * 43758.5453) }
            let wobble = { (a: Double, p: Double) in 1 + a * (0.6 * sin(t / p) + 0.25 * sin(t / (p * 0.37) + 1) + 0.3 * (jitter(p) - 0.5)) }
            // CPU: 8 cores (4 performance, 4 efficiency)
            var cores = Array(template.cpu.cores.prefix(8))
            while cores.count < 8, let c = template.cpu.cores.first { cores.append(c) }
            for k in cores.indices {
                cores[k].index = k; cores[k].kind = k < 4 ? .performance : .efficiency
                cores[k].user = min(92, (k < 4 ? 58 : 34) * wobble(0.25, 3 + Double(k))); cores[k].system = k < 4 ? 9 : 6
            }
            s.cpu.cores = cores
            let total = cores.reduce(0) { $0 + $1.total } / Double(cores.count)
            s.cpu.total = .value(total); s.cpu.user = .value(total * 0.85); s.cpu.system = .value(total * 0.15)
            s.cpu.loadAverage = [6.4, 5.8, 4.9]
            // Memory: 32 GB, moderately pressured
            let gb = 1_073_741_824.0
            s.memory.total = UInt64(32 * gb); s.memory.app = UInt64(15.2 * gb); s.memory.wired = UInt64(3.1 * gb)
            s.memory.compressed = UInt64(4.6 * gb); s.memory.used = s.memory.app + s.memory.wired + s.memory.compressed
            s.memory.cached = UInt64(6.4 * gb); s.memory.free = UInt64(1.9 * gb)
            s.memory.pressure = .value(46 * wobble(0.05, 7)); s.memory.pressureLevel = 1
            s.memory.swapUsed = .value(1.3 * gb); s.memory.swapTotal = .value(3 * gb)
            s.memory.pageSize = 16384; s.memory.swapOuts = UInt64(1000 + i * 40); s.memory.swapIns = UInt64(500 + i * 25)
            s.memory.compressions = UInt64(200_000 + i * 900); s.memory.pageIns = 4_200_000; s.memory.pageOuts = 12_000; s.memory.decompressions = 150_000
            // Disk: Spotlight indexing
            s.disk.readBps = .value(118e6 * wobble(0.3, 4)); s.disk.writeBps = .value(36e6 * wobble(0.4, 5))
            if var v = template.disk.volumes.first {
                v.name = "Macintosh HD"; v.path = "/"; v.capacity = 994_662_584_320; v.available = 312_500_000_000; v.fileSystem = "apfs"; v.isInternal = true
                s.disk.volumes = [v]
            }
            s.disk.devices = Array(template.disk.devices.prefix(1)).map { var d = $0; d.name = "disk0"; d.readBps = 118e6; d.writeBps = 36e6; return d }
            // Network
            s.network.inBps = .value(2.9e6 * wobble(0.5, 2.5)); s.network.outBps = .value(0.35e6 * wobble(0.5, 3.5))
            s.network.totalIn = 18_400_000_000; s.network.totalOut = 2_100_000_000
            s.network.interfaces = Array(template.network.interfaces.prefix(1)).map { var n = $0; n.name = "en0"; n.addresses = []; n.mac = nil; return n }
            // Power and thermals: on battery, warm
            // Charging on the invented 96 W USB-C charger (the same session DemoCharging shows), so every power panel
            // agrees. Every battery field is overwritten: none of this Mac's battery or charger may appear in demo mode.
            s.power.systemWatts = .value(24 * wobble(0.12, 6)); s.power.batteryWatts = .value(48)
            s.power.powerSource = "AC Power"; s.power.lowPowerMode = false; s.power.thermalState = 1
            if var b = s.power.battery {
                b.percent = 62; b.isCharging = true; b.externalConnected = true; b.cycleCount = 214
                b.maxCapacity = 4_620; b.designCapacity = 5_000; b.temperature = 31.5; b.voltage = 12.42; b.amperage = 3.86
                b.timeRemaining = 58; b.adapterWatts = 96
                s.power.battery = b
            }
            // Charging details are this Mac's real readings in the template: never shown in demo mode.
            s.power.charging = nil
            // Invented sensors in the layouts Apple-silicon MacBooks publish (HID cluster/die names plus the common
            // SMC keys), catalogued with the generic Apple-silicon table, so no reading or name comes from this Mac.
            let (hid, smc) = sensors(wobble: wobble)
            s.power.temperatures = hid
            s.power.smcTemperatures = smc
            // The real sampler re-reads sensors every 4 s; demo frames do the same so statistics count each read once.
            s.power.sensorsReadAt = Date(timeIntervalSince1970: (time.timeIntervalSince1970 / 4).rounded(.down) * 4)
            s.power.hottest = .value((hid + smc).filter { $0.name != "PMU tcal" }.map(\.celsius).max() ?? 79)
            // Two invented fans (not this Mac's), so the fan panels and the "why is the fan loud?" card always have data.
            s.power.fans = [FanReading(index: 0, rpm: 3150 * wobble(0.04, 6), minRPM: 1200, maxRPM: 5800, targetRPM: 3150),
                            FanReading(index: 1, rpm: 3020 * wobble(0.04, 7), minRPM: 1200, maxRPM: 5800, targetRPM: 3150)]
            // GPU
            s.gpu = .value(44 * wobble(0.2, 3))
            if var g = s.gpuDetail {
                g.deviceUtilization = 44 * wobble(0.2, 3); g.rendererUtilization = 41; g.tilerUtilization = 39
                g.frequencyMHz = 980; g.activeResidency = 71; g.powerWatts = 6.2; g.memoryInUse = UInt64(2.4 * gb); g.recoveryCount = 0
                g.thermalLimited = 0; g.clients = []
                g.cpuClusters = g.cpuClusters.enumerated().map { j, c in var c = c; c.mhz = j == 0 ? 2064 : 3036; c.active = j == 0 ? 52 : 74; return c }
                s.gpuDetail = g
            }
            s.wifi = nil; s.latency = nil; s.drives = nil
            s.processes = processes(template: template.processes.first!, i: i, wobble: wobble)
            return s
        }
    }

    /// Invented HID and SMC temperature readings for one frame: a warm Mac exporting photos.
    static func sensors(wobble: (Double, Double) -> Double) -> (hid: [SensorReading], smc: [SensorReading]) {
        var hid: [SensorReading] = [], smc: [SensorReading] = []
        func add(_ list: inout [SensorReading], _ name: String, _ c: Double, _ seed: Double) {
            list.append(SensorReading(name: name, celsius: c * wobble(0.02, 5 + seed)))
        }
        for (i, c) in [78.0, 81, 76, 79].enumerated() { add(&hid, "pACC MTR Temp Sensor\(i)", c, Double(i)) }
        for (i, c) in [63.0, 65, 62, 64].enumerated() { add(&hid, "eACC MTR Temp Sensor\(i)", c, Double(i) + 4) }
        for (i, c) in [69.0, 71, 68, 70].enumerated() { add(&hid, "GPU MTR Temp Sensor\(i)", c, Double(i) + 8) }
        for (i, c) in [66.0, 64].enumerated() { add(&hid, "SOC MTR Temp Sensor\(i)", c, Double(i) + 12) }
        add(&hid, "ANE MTR Temp Sensor1", 52, 14); add(&hid, "PMU tdie1", 67, 15); add(&hid, "PMU tdie2", 68, 16)
        add(&hid, "PMU tcal", 51, 17); add(&hid, "NAND CH0 temp", 46, 18)
        for (k, c, seed) in [("TB0T", 34.0, 19.0), ("TB1T", 33.4, 20), ("TB2T", 34.0, 21), ("TW0P", 48, 22), ("TH0x", 46.3, 23),
                             ("TaLP", 41, 24), ("TaRF", 43, 25), ("Ts0P", 32, 26), ("Ts1P", 31, 27)] {
            add(&smc, k, c, seed)
        }
        return (hid, smc)
    }

    /// Invented pmset limits: full speed (a warm but unthrottled Mac).
    static let thermalLimits = ThermalLimits(cpuSpeedLimit: 100, cpuSchedulerLimit: 100, availableCPUs: 8)

    // MARK: Live demo mode (`-demo YES`): the real app UI driven only by this file's data

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demo") }
    private static var timer: Timer?

    /// Fills a headless engine with demo state and keeps feeding it a new synthetic frame every second.
    static func start(_ e: Engine) {
        let sampler = Sampler(); _ = sampler.sample()
        let template = sampler.sample()   // structure only; every shown field is overwritten
        let analyzer = Analyzer()
        let now = Date()
        e.thermal.note(limits: thermalLimits, at: now)
        for f in frames(template: template, count: 120) { e.feed(f, findings: analyzer.ingest(f)) }
        e.chromeTabs = DemoChromeTabs.attribution(for: e.current?.processes ?? [])   // invented; demo never opens the tab socket
        e.demoInject(incidents: incidents(now), reports: reports(now), rules: demoRules, ruleLog: demoRuleLog(now))
        e.demoTimeline = timeline(template: template, now: now)
        e.demoMarks = marks(now: now)
        e.demoSleep = sleepReport(now: now)
        e.dailyLog.replaceForDemo(days: trendDays(now: now), charge: chargeStatus(now: now))   // Trends (in memory only)
        var i = 120
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let f = frame(template: template, i: i, time: Date()); i += 1
                if i % 30 == 0 { e.thermal.note(limits: thermalLimits, at: f.time) }   // as the tab's 30 s pmset poll would
                e.feed(f, findings: analyzer.ingest(f))
            }
        }
    }

    static var demoRules: [Rule] { var r = RuleEngine.examples; r[0].enabled = true; return r }
    static func demoRuleLog(_ now: Date) -> [Engine.RuleLogEntry] {
        [Engine.RuleLogEntry(id: UUID(), time: now.addingTimeInterval(-600), rule: "Runaway app", action: "Notify me", subject: "Photos", result: "Notified"),
         Engine.RuleLogEntry(id: UUID(), time: now.addingTimeInterval(-9_000), rule: "Tame background indexing", action: "Lower its priority", subject: "mds_stores", result: "Lowered the priority of 1 of 1 processes")]
    }

    static func processes(template: ProcessSample, i: Int, wobble: (Double, Double) -> Double) -> [ProcessSample] {
        var out: [ProcessSample] = []
        var pid: Int32 = 400
        for a in apps {
            for k in 0..<a.procs {
                pid += 7
                var p = template
                let share = a.procs == 1 ? 1 : (k == 0 ? 0.5 : 0.5 / Double(a.procs - 1))
                p.identity = ProcessIdentity(pid: a.name == "kernel_task" ? 0 : pid, startTime: 1_700_000_000_000_000 + UInt64(pid))
                p.ppid = 1
                p.name = k == 0 ? a.name : "\(a.name) Helper\(a.procs > 2 ? " \(k)" : "")"
                p.path = k == 0 ? a.path : a.path.replacingOccurrences(of: "/MacOS/\(a.name)", with: "/Helpers/\(a.name) Helper")
                // System daemons run as their own accounts, as on a real Mac; everything else is the signed-in user.
                (p.user, p.uid) = a.name == "WindowServer" ? ("_windowserver", 88) : a.path.isEmpty || a.name == "mds_stores" ? ("root", 0) : ("you", 501)
                p.restricted = false
                p.cpu = a.cpu * share * wobble(0.15, 2 + Double(k)); p.cpuTime = 3600 * a.cpu / 100 * share
                p.memory = UInt64(a.memGB * share * 1_073_741_824); p.threads = 6 + 4 * k
                p.diskReadBps = a.diskMB * 0.8e6 * share; p.diskWriteBps = a.diskMB * 0.2e6 * share
                p.diskRead = 0; p.diskWritten = 0
                p.energyWatts = a.watts * share; p.energyTotal = nil; p.wakeups = a.wakeups * share
                p.network = ProcessNetwork(inBps: a.netKB * 1000 * share, outBps: a.netKB * 120 * share, totalIn: UInt64(a.netKB * 1e6 * share),
                                           totalOut: UInt64(a.netKB * 1.2e5 * share), connections: a.netKB > 0 ? 3 : 0)
                p.gpu = a.gpu.map { $0 * share }
                p.notResponding = a.hung && k == 0 ? true : (a.path.hasPrefix("/System/Applications") || a.path.hasPrefix("/Applications") ? false : nil)
                p.translated = false; p.powerAssertions = a.name == "Music" && k == 0 ? [PowerAssertion(type: "PreventUserIdleSystemSleep", name: "Playing audio")] : nil
                out.append(p)
            }
        }
        return out
    }

    static func incidents(_ now: Date) -> [Incident] {
        func inc(_ ago: Double, _ len: Double, _ sev: Finding.Severity, _ icon: String, _ title: String, _ detail: String, ev: String? = nil) -> Incident {
            Incident(id: UUID(), key: title, severity: sev, icon: icon, title: title, detail: detail, destination: "Processes",
                     start: now.addingTimeInterval(-ago), end: now.addingTimeInterval(-ago + len), evidencePath: nil, evidenceSummary: ev)
        }
        return [
            inc(26_000, 540, .caution, "chart.line.uptrend.xyaxis", "Safari (14 processes) keeps using more memory: +2.1 GB in 22 min",
                "It now uses 5.8 GB. Steady growth like this often means a memory leak; restarting the app frees the memory."),
            inc(14_400, 1500, .info, "internaldrive", "Heavy disk activity (131 MB/s), mostly mds_stores",
                "Spotlight is indexing files. It finishes on its own, usually after big copies or updates."),
            inc(5_400, 95, .warning, "hourglass", "Mail is not responding",
                "Its main thread is stuck. Open it in the inspector and sample its stacks to see where, or Force Quit it.",
                ev: "Main thread waiting (97% of samples) in __psynch_mutexwait (libsystem_kernel.dylib) ← -[MailboxIndex rebuild] (Mail)"),
            inc(2_100, 1260, .caution, "cpu", "Photos is using 165% CPU", "Quit it or let it finish if you don't need it right now.",
                ev: "Main thread busy (88% of samples) in vImageConvert_ARGB8888toRGB888 (Accelerate) ← -[ExportSession encodeFrame:] (Photos)"),
            inc(600, 0, .info, "bolt.badge.automatic", "Rule “Runaway app”: Notified", "Photos: CPU % 165.0 for 10 min"),
        ]
    }

    static func reports(_ now: Date) -> [DiagnosticReport] {
        [DiagnosticReport(path: "/demo/1", kind: .hang, process: "Mail", time: now.addingTimeInterval(-5_300), summary: "lasted 95.20s"),
         DiagnosticReport(path: "/demo/2", kind: .diskWrites, process: "Video Exporter", time: now.addingTimeInterval(-40_000),
                          summary: "2147.48 MB of file backed memory dirtied over 312 seconds, exceeding limit of 24.86 KB per second over 86400 seconds"),
         DiagnosticReport(path: "/demo/3", kind: .cpuLimit, process: "Photo Analysis", time: now.addingTimeInterval(-70_000),
                          summary: "90 seconds cpu time over 141 seconds (64% cpu average), exceeding limit of 50% cpu over 180 seconds"),
         DiagnosticReport(path: "/demo/4", kind: .crash, process: "Code Editor", time: now.addingTimeInterval(-130_000), summary: "EXC_BAD_ACCESS / SIGSEGV")]
    }

    /// 24 h of coarse history with a night-time sleep gap, folded into timeline buckets.
    static func timeline(template: Snapshot, now: Date) -> (buckets: [TimelineBucket], range: (Date, Date)) {
        let from = now.addingTimeInterval(-86_400)
        var frames: [Snapshot] = []
        for m in stride(from: 0, to: 1440, by: 6) {
            let hoursAgo = Double(1440 - m) / 60
            if hoursAgo > 9 && hoursAgo < 16 { continue }   // asleep overnight: no data
            var s = template
            s.time = from.addingTimeInterval(Double(m) * 60)
            let busy = hoursAgo < 0.7 ? 0.9 : (hoursAgo > 4 && hoursAgo < 4.6 ? 0.7 : 0.25 + 0.15 * sin(Double(m) / 40))
            s.cpu.total = .value(busy * 100); s.memory.pressure = .value(30 + busy * 25); s.power.hottest = .value(48 + busy * 34)
            frames.append(s)
        }
        return (Timeline.build(frames, from: from, to: now, buckets: 240), (from, now))
    }

    /// Marks a coding agent might have set: a baseline test run and the run with its change, during the busy
    /// spells of the demo timeline.
    static func marks(now: Date) -> [Mark] {
        [("baseline-start", 4.55), ("baseline-end", 4.1), ("change-start", 0.65), ("change-end", 0.2)].enumerated().map { i, m in
            Mark(id: "m-demo\(i)", label: m.0, time: now.addingTimeInterval(-m.1 * 3600), source: "mcp")
        }
    }

    /// A restless night, as power-log lines run through the real parser.
    static func sleepReport(now: Date) -> SleepReport {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        func at(_ hoursAgo: Double) -> String { f.string(from: now.addingTimeInterval(-hoursAgo * 3600)) }
        var lines: [String] = []
        // Two nights: last night restless and draining, the one before calm.
        for (night, start, wakes, charge0) in [(1, 15.5, 34, 88), (2, 39.5, 9, 96)] {
            _ = night
            lines.append("\(at(start)) Sleep               \tEntering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:\(charge0)%) 600 secs")
            for k in 0..<wakes {
                let h = start - 0.2 - Double(k) * (7.0 / Double(wakes))
                let reason = k % 3 == 0 ? "NUB.SPMISw3IRQ nub-spmi0.0x02 rtc/Maintenance" : (k % 3 == 1 ? "smc.sysState.Wake(0x70070000) bluetooth-pcie/" : "smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty E_RX_IP_PACKET ARPT/")
                lines.append("\(at(h)) DarkWake            \tDarkWake from Deep Idle [CDNPB] : due to \(reason) Using BATT (Charge:\(charge0 - k / 3)%) 12 secs")
                lines.append("\(at(h - 0.004)) Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using BATT (Charge:\(charge0 - k / 3)%) 600 secs")
            }
            lines.append("\(at(start - 7.5)) Wake                \tDarkWake to FullWake from Deep Idle [CDNVA] : due to EC.LidOpen/Lid Open Using BATT (Charge:\(charge0 - wakes / 3 - 1)%)")
        }
        lines.append("\(at(10)) Wake Requests       \t[process=mDNSResponder request=Maintenance deltaSecs=7198] [process=dasd request=SleepService deltaSecs=999]")
        lines.append("\(at(9)) Assertions          \tPID 610(Music) Released PreventUserIdleSystemSleep \"Playing audio\" 01:12:40 id:0x1 [System: x]")
        lines.append("\(at(8)) Assertions          \tPID 702(Safari) Released NoDisplaySleepAssertion \"Video Wake Lock\" 00:24:05 id:0x2 [System: x]")
        return SleepLog.parse(lines.sorted().joined(separator: "\n"), since: now.addingTimeInterval(-3 * 86_400))
    }
}
