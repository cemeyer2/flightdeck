// Developer tooling reached via CLI flags: renders views off-screen into PNGs or times their render cost, using a
// headless Engine fed with real samples. `\.offscreen` is set so MaybeScroll doesn't wrap content in a ScrollView
// (which ImageRenderer renders empty).
import SwiftUI
import FlightDeckCore

/// `FlightDeck --bench-ui [renders]`: renders each main view off-screen with real data and reports the cost
/// per frame, so UI overhead can be measured without opening a window.
@MainActor
enum UIBench {
    /// Writes a 2x PNG of each main view (for visual review without opening a window).
    /// Collects ~10 s of real samples first so graphs have history. Set FD_RENDER_ALL to also render the inventory
    /// views; their loaders run asynchronously, so the main run loop is spun for 2 s before each one.
    static func renderViews(to dir: String) -> Never {
        // Line-buffered stdout, so a crash mid-run still shows the last "wrote …" line (CI pipes the output).
        setvbuf(stdout, nil, _IOLBF, 0)
        let e = Engine(headless: true)
        let sampler = Sampler(); let analyzer = Analyzer()
        _ = sampler.sample()
        for _ in 0..<40 { Thread.sleep(forTimeInterval: 0.25); let s = sampler.sample(); e.feed(s, findings: analyzer.ingest(s)) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = Palette.of(.dark)
        func out<V: View>(_ name: String, width: CGFloat = 1100, height: CGFloat = 1500, engine: Engine? = nil, _ v: V) {
            let r = ImageRenderer(content: v.environmentObject(engine ?? e).environment(\.palette, p).environment(\.colorScheme, .dark).environment(\.offscreen, true)
                .padding(16).frame(width: width, height: height, alignment: .top).background(p.background))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")); print("wrote \(name).png")
            }
        }
        out("summary", SummaryView())
        for r in cockpitRenders() { out(r.name, width: r.width, height: r.height, r.view) }   // CockpitBench.swift
        out("stressmap", height: 900, StressMapView())
        out("welcome", height: 640, WelcomeView())
        out("sleep", height: 1500, SleepPreview())
        // Restarts & Crashes: the invented history, then this Mac's records (wtmp, shutdown log, panic and hang reports,
        // a few unified-log queries), loaded before building the view (see `ready` below). The saved history is only read.
        out("restarts-demo", height: 3000, RestartsView(model: RestartsModel(preview: DemoRestarts.report())))
        let restartsLive = RestartsModel.loadedForRender(blackBox: e.blackBox)
        out("restarts", height: 2600, RestartsView(model: restartsLive))
        if ProcessInfo.processInfo.environment["FD_RENDER_ONLY"] == "restarts" { exit(0) }   // quick iteration on this page
        out("flightlog", FlightLogView())
        // The timeline with demo buckets and marks (as a coding agent's `mark` calls would leave them), handed in
        // because ImageRenderer doesn't run the panel's loading task.
        if let template = e.current {
            let now = Date()
            out("timeline-marks", height: 260, TimelinePanel(preview: Demo.timeline(template: template, now: now), previewMarks: Demo.marks(now: now)))
        }
        out("cpu", VStack { CPUPerf() })
        out("memory", height: 1900, VStack { MemoryPerf() })
        out("gpu", height: 2200, VStack { GPUPerf() })
        out("thermals", height: 3000, VStack { ThermalPerf() })
        // Temperature alert settings and the menu bar's temperature readout, drawn as the label image would be.
        out("thermal-settings", width: 640, height: 420, VStack(alignment: .leading) { TemperatureAlertsSection(); MenuBarTemperatureSettings() })
        let mbText = MenuBarTemperature.text(e.liveSnapshot, choice: "family:cpu", fan: true, chip: e.thermal.chip)
        out("menubar-temp", width: 300, height: 60, Image(nsImage: MenuBarLabel.render(cpu: 0.4, mem: 0.6, severity: nil, lightOnly: false, suffix: mbText)))
        // Console: a real 5-minute query, finished before rendering (the view itself only starts queries on appear).
        let console = ConsoleModel(); console.span = .m5; console.load()
        let deadline = Date().addingTimeInterval(30)
        while console.loading && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        out("console", height: 2000, ConsoleView(model: console))
        // Thermals again from demo data, so the "why is the fan loud?" card can be reviewed on a cool Mac too.
        if let template = e.current {
            let demo = Engine(headless: true, chip: .appleSilicon), a = Analyzer()
            demo.thermal.note(limits: Demo.thermalLimits, at: Date())
            for f in Demo.frames(template: template, count: 30) { demo.feed(f, findings: a.ingest(f)) }
            out("thermals-demo", height: 2600, engine: demo, VStack { ThermalPerf() })
            // Ambient with the demo's findings, so the lit master caution light and the ticker can be reviewed.
            out("ambient-demo", width: 1600, height: 1000, engine: demo, ambientPreview())
        }
        // Trends: first with this headless engine's empty in-memory log (the "needs more days" states), then with
        // demo history and a demo battery session (the headless log is never persisted).
        out("trends-empty", height: 1300, TrendsPreview(log: e.dailyLog))
        e.dailyLog.replaceForDemo(days: Demo.trendDays(), charge: Demo.chargeStatus())
        out("trends", height: 2300, TrendsPreview(log: e.dailyLog))
        out("trends-90", height: 2300, TrendsPreview(log: e.dailyLog, days: 90))
        out("charge-drain", height: 400, ChargeDrainPanel(preview: Demo.chargeStatus()))
        // Charging insights: this Mac's live readings, then the invented demo session (96 W USB-C PD at 20 V).
        out("charging", height: 1400, ChargingSection())
        out("charging-demo", height: 1400, ChargingSection(preview: DemoCharging.inputs()))
        // Battery health: this Mac's saved history (read-only: a log that never ingests never writes) with macOS's
        // power-log seed merged in memory, then the demo's 400 invented days, then a desktop. Reports are built before
        // the views (see `ready` below for why loads never run inside a view argument).
        let liveB = e.current?.power.battery, liveFacts = e.current?.power.charging?.facts
        let saved = DailyLog(dir: DailyLog.defaultDirectory).batteryHistory()
        let seed = liveB == nil ? nil : PowerLogBattery.read(designCapacity: liveFacts?.designCapacity ?? liveB?.designCapacity)
        let liveReport = BatteryReport(battery: liveB, facts: liveFacts, condition: nil, history: BatteryHistory.merge(seed?.days ?? [], saved.days),
                                       lifetime: saved.lifetime ?? seed?.lifetime)
        out("battery-health", height: 1100, BatteryHealthPanel(report: liveReport))
        let demoReport = DemoCharging.inputs().report
        out("battery-health-demo", height: 1100, BatteryHealthPanel(report: demoReport))
        out("battery-health-desktop", height: 400, ChargingContent(inputs: ChargingInputs()))
        // UniFi: the invented demo network (no console is contacted), with a client selected in the detail pane.
        UniFiModel.shared.renderDemo(ticks: 12)
        out("unifi", height: 2300, UniFiView())
        let demoNet = UniFiDemo.snapshot()
        out("unifi-client", height: 600, UniFiClientDetail(client: demoNet.clients[0], snapshot: demoNet).frame(width: 360))
        // Internet: invented speed tests and data usage (networkQuality never runs here), then the real page: no test
        // history, and data usage counted by an in-memory log from ~16 s of real nettop samples.
        out("internet-demo", height: 2100, InternetView(model: InternetModel(preview: Demo.speedTests()), previewUsage: DataUsageReport.build(days: Demo.dataUsageDays())))
        var usageConfig = DailyLog.Config(); usageConfig.appInterval = 4
        let usageLog = DailyLog(dir: nil, config: usageConfig), usageSampler = Sampler()
        for _ in 0..<16 { usageLog.ingest(usageSampler.sample()); Thread.sleep(forTimeInterval: 1) }
        out("internet", height: 1500, InternetView(model: InternetModel(preview: [], demo: false), previewUsage: DataUsageReport.build(days: usageLog.history().days)))
        if ProcessInfo.processInfo.environment["FD_RENDER_ALL"] != nil {
            for d in [Destination.systemInfo, .startup, .users, .services, .power, .connections, .apps, .diskSpace, .benchmarks] {
                let v: AnyView
                switch d {
                case .systemInfo: v = AnyView(SystemInfoView()); case .startup: v = AnyView(StartupView()); case .users: v = AnyView(UsersView())
                case .services: v = AnyView(ServicesView()); case .power: v = AnyView(PowerView()); case .connections: v = AnyView(ConnectionsView())
                case .apps: v = AnyView(InstalledAppsView()); case .diskSpace: v = AnyView(DiskSpaceView()); default: v = AnyView(BenchmarksView())
                }
                RunLoop.main.run(until: Date().addingTimeInterval(2))   // loaders
                out(d.rawValue.replacingOccurrences(of: " ", with: "_"), height: 1300, v)
            }
        }
        // Disk Space › What's using my disk: this Mac's real breakdown (diskutil/tmutil only) before Analyze, then the
        // invented demo disk with a few rows open. FD_RENDER_HOGS also measures this Mac's categories that macOS doesn't
        // guard with a privacy prompt (so the render can't trigger one).
        out("diskusage", height: 1300, DiskUsageOverview(model: StorageModel(preview: false, breakdown: StorageBreakdownReader.read(), results: [])))
        out("diskusage-demo", height: 2600, DiskUsageOverview(model: StorageModel(preview: true, breakdown: .success(Demo.storageBreakdown()),
                                                                                   results: Demo.hogResults(), expanded: ["caches", "downloads", "messages", "simDevices"])))
        if ProcessInfo.processInfo.environment["FD_RENDER_HOGS"] != nil {
            var real: [HogResult] = []
            SpaceHogScanner.analyze(SpaceHogCategory.catalog.filter { !$0.privacyProtected }, result: { real.append($0) }, cancelled: { false })
            out("diskusage-real", height: 2600, DiskUsageOverview(model: StorageModel(preview: false, breakdown: StorageBreakdownReader.read(),
                                                                                       results: real, expanded: ["caches", "simDevices", "homebrew"])))
        }
        // Checkup, Peripherals and the listening-ports panel read the real machine; their loaders run asynchronously,
        // so the run loop is spun until each has a result (Checkup waits on the black box and ~17 tools).
        CheckupModel.shared.run(engine: e)
        let until = Date().addingTimeInterval(30)
        while CheckupModel.shared.running && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        out("checkup", height: 2000, CheckupView())
        // The loaders are started and awaited here and handed to the views, since ImageRenderer doesn't run onAppear.
        // Always call this *before* building the view, never inline as a view argument: a @StateObject initializer
        // runs during SwiftUI's graph update, and spinning the run loop there re-enters SwiftUI and aborts (an
        // AttributeGraph precondition). That only happened when the load was slow enough to spin, as on CI's VMs.
        func ready<T>(_ l: Loader<T>) -> Loader<T> {
            l.load(); let until = Date().addingTimeInterval(30)
            while l.value == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            return l
        }
        // Peripherals: the invented desk, then this Mac with its saved accessory history read-only (nothing recorded).
        let peripheralsDemo = ready(Loader { DemoPeripherals.report() })
        out("peripherals-demo", height: 1900, PeripheralsView(loader: peripheralsDemo))
        let peripherals = ready(Loader {   // before building the view: see `ready`
            Peripherals.collect(recorder: AccessoryRecorder(store: AccessoryStore(dir: AccessoryStore.defaultDirectory, readOnly: true)))
        })
        out("peripherals", height: 1500, PeripheralsView(loader: peripherals))
        // UPnP: the invented demo network, then a real ~3 s SSDP scan of this network (run here, since onAppear doesn't).
        out("upnp-demo", height: 1250, UPnPView(model: UPnPModel(preview: Demo.upnpScan())))
        let upnp = Loader { UPnPScan.run() }
        if let s = ready(upnp).value { out("upnp", height: 1500, UPnPView(model: UPnPModel(preview: s))) }
        // Network: the invented demo network, then this Mac's real one from the passive sources only (interfaces,
        // routes, ARP/NDP, reverse DNS). Bonjour is skipped here unless FD_RENDER_BONJOUR is set, since browsing can
        // raise macOS's Local Network permission prompt for whatever launched the render.
        out("network-demo", height: 1250, NetworkMapView(model: NetworkMapModel(survey: Demo.networkSurvey())))
        let bonjour = ProcessInfo.processInfo.environment["FD_RENDER_BONJOUR"] != nil ? BonjourBrowser.browse() : []
        let live = NetworkDiscovery.survey(services: bonjour, knownNames: [:], seen: [:], hops: []).0
        out("network", height: 1250, NetworkMapView(model: NetworkMapModel(survey: live)))
        // Wi-Fi: the invented neighbourhood and link history (no scan), with walk test on; then this Mac's real link
        // from the samples above, without a scan (scanning disrupts Wi-Fi), so the page's pre-scan state is reviewed.
        // Models are built before the views (see `ready`).
        let wifiDemo = WiFiModel(demo: true); wifiDemo.walkTest = true
        out("wifi-demo", height: 2900, WiFiView(model: wifiDemo))
        let wifiLive = WiFiModel(preview: nil, history: e.frames.compactMap { f in f?.wifi.map { WiFiLinkPoint($0, time: f!.time) } },
                                 link: e.current?.wifi.map { w in WiFiLinkNow(ssid: w.ssid, phy: w.phy, security: w.security, point: WiFiLinkPoint(w, time: Date())) },
                                 permission: WiFiPermission.status(), demo: false)
        out("wifi", height: 1300, WiFiView(model: wifiLive))
        // Developer: invented data (no tool is run), then this Mac's real dev servers, containers, services and
        // toolchains. Read-only: loading never starts, stops or restarts anything.
        out("developer-demo", height: 1900, DeveloperView(model: DeveloperModel(demo: true)))
        let dev = DeveloperModel(demo: false); dev.refreshAll()
        let devUntil = Date().addingTimeInterval(45)
        while !dev.busy.isEmpty && Date() < devUntil { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        out("developer", height: 1900, DeveloperView(model: dev))
        let ports = ready(Loader { ListeningPorts.scan() })   // before building the view: see `ready`
        out("listening_ports", height: 420, ListeningPortsPanel(loader: ports).frame(maxHeight: .infinity, alignment: .top))
        // The inspector is rendered for FlightDeck's own process, which is always present.
        if let me = e.current?.processes.first(where: { $0.pid == getpid() }) {
            let model = InspectorModel(identity: me.identity, engine: e)
            for _ in 0..<2 {   // let the background detail loads finish (two, so rates exist)
                RunLoop.main.run(until: Date().addingTimeInterval(1.5)); model.refreshDetails()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            out("inspector", height: 1700, InspectorView(model: model))
            // Memory breakdown of FlightDeck itself (its own process, so footprint can read it).
            let mem = MemoryBreakdownReader.read(pid: getpid(), ownedByUser: true)
            out("inspector-memory", height: 900, MemoryBreakdownPanel(model: model, result: mem))
        }
        // Camera & Mic: invented sessions (no listeners, nothing written) in each range, then this Mac: its saved history,
        // read-only, and one reading of the devices (never opens a camera or microphone). Models are built first.
        let cmDemo = CameraMicModel(preview: DemoCameraMic.sessions(now: Date()), live: DemoCameraMic.live(now: Date()))
        out("cameramic-demo-today", height: 1700, CameraMicView(model: cmDemo, range: .today))
        out("cameramic-demo", height: 2600, CameraMicView(model: cmDemo, range: .month))
        let cmLive = CameraMicModel(preview: CameraMicStore(dir: DailyLog.defaultDirectory, readOnly: true).sessions(),
                                    live: CameraMicWatch.reading(), demo: false)
        out("cameramic", height: 1300, CameraMicView(model: cmLive, range: .week))
        out("cameramic-settings", width: 700, height: 220, VStack(alignment: .leading) { CameraMicAlertsSection() })
        out("cameramic-menubar", width: 360, height: 60, CameraMicMenuBarRow(model: cmDemo))
        for r in destinationRenders(template: e.current?.processes.first) { out(r.name, width: r.width, height: r.height, r.view) }   // DestinationsBench.swift; models load first
        // Power tools: Launches (real launches seen during the ~10 s of sampling above), the palette with a query, and
        // the diagnostic capture sheet before and after a (simulated) run.
        out("launches", height: 1100, LaunchesView())
        out("palette", height: 700, CommandPaletteView(engine: e, initialQuery: "fl"))
        out("palette-empty", height: 900, CommandPaletteView(engine: e))
        out("capture", height: 700, DiagnosticCaptureView())
        var done = DiagnosticCapture.steps(.init(blackBox: nil, summary: "", targets: [], reportsSince: Date()))
        for i in done.indices { done[i].state = i == 2 ? .skipped : .done; done[i].detail = i == 2 ? "none in the last 24 hours" : nil }
        out("capture-done", height: 700, DiagnosticCaptureView(phase: .finished(URL(fileURLWithPath: "/tmp/FlightDeck Diagnostics.zip")), steps: done))
        exit(0)
    }

    /// Prints the average time per full render of each view, in ms. Each iteration uses a new ImageRenderer so no
    /// cached image is reused; the first render is a discarded warm-up.
    static func run(renders: Int) -> Never {
        let e = Engine(headless: true)
        let sampler = Sampler(); let analyzer = Analyzer()
        _ = sampler.sample()
        print("collecting 30 samples…")
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.2)
            let s = sampler.sample()
            e.feed(s, findings: analyzer.ingest(s))
        }
        let p = Palette.of(.dark)
        func bench<V: View>(_ name: String, _ v: V) {
            let content = v.environmentObject(e).environment(\.palette, p).environment(\.offscreen, true).frame(width: 1100, height: 1400)
            _ = ImageRenderer(content: content).cgImage   // warm up
            let t = Date()
            for _ in 0..<renders { _ = ImageRenderer(content: content).cgImage }   // fresh renderer: no cached image
            let ms = Date().timeIntervalSince(t) / Double(renders) * 1000
            print(name.padding(toLength: 22, withPad: " ", startingAt: 0) + String(format: "%6.1f ms/frame", ms))
        }
        bench("Summary", SummaryView())
        bench("Cockpit (edit mode)", CockpitView(model: CockpitModel(preview: editedCockpit(), editing: true)))
        bench("Ambient", ambientPreview())
        bench("Flight Log", FlightLogView())
        for t in PerfTab.allCases {
            bench("Perf › \(t.rawValue)", Group {
                switch t {
                case .cpu: CPUPerf(); case .memory: MemoryPerf(); case .disk: DiskPerf(); case .network: NetworkPerf()
                case .energy: EnergyPerf(); case .thermals: ThermalPerf(); case .gpu: GPUPerf()
                }
            })
        }
        bench("· AppNetworkPanel", AppNetworkPanel())
        bench("· ConnectionQuality", ConnectionQualityPanel())
        bench("· DriveHealth", DriveHealthPanel())
        bench("· EnergyBudget", EnergyBudgetPanel())
        e.dailyLog.replaceForDemo(days: Demo.trendDays(), charge: Demo.chargeStatus())
        bench("Trends (demo data)", TrendsPreview(log: e.dailyLog, days: 90))
        // Micro-benchmarks of pieces that views compute on every render.
        let g = e.current!
        bench("· aggregate x1", Text("\(AppUsage.aggregate(g.processes).count)"))
        bench("· HistoryGraph", HistoryGraph(traces: [GraphTrace(name: "c", values: e.series { $0.cpu.total.value }, color: .blue)], maxValue: 100).frame(height: 200))
        bench("Menu bar panel", MenuBarPanel())
        bench("Dock-size label", MenuBarLabel())
        exit(0)
    }
}
