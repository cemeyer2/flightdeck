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
        let e = Engine(headless: true)
        let sampler = Sampler(); let analyzer = Analyzer()
        _ = sampler.sample()
        for _ in 0..<40 { Thread.sleep(forTimeInterval: 0.25); let s = sampler.sample(); e.feed(s, findings: analyzer.ingest(s)) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = Palette.of(.dark)
        func out<V: View>(_ name: String, height: CGFloat = 1500, engine: Engine? = nil, _ v: V) {
            let r = ImageRenderer(content: v.environmentObject(engine ?? e).environment(\.palette, p).environment(\.colorScheme, .dark).environment(\.offscreen, true)
                .padding(16).frame(width: 1100, height: height, alignment: .top).background(p.background))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")); print("wrote \(name).png")
            }
        }
        out("summary", SummaryView())
        out("stressmap", height: 900, StressMapView())
        out("welcome", height: 640, WelcomeView())
        out("sleep", height: 1500, SleepPreview())
        out("flightlog", FlightLogView())
        out("cpu", VStack { CPUPerf() })
        out("memory", height: 1900, VStack { MemoryPerf() })
        out("gpu", height: 2200, VStack { GPUPerf() })
        out("thermals", VStack { ThermalPerf() })
        // Console: a real 5-minute query, finished before rendering (the view itself only starts queries on appear).
        let console = ConsoleModel(); console.span = .m5; console.load()
        let deadline = Date().addingTimeInterval(30)
        while console.loading && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        out("console", height: 2000, ConsoleView(model: console))
        // Thermals again from demo data, so the "why is the fan loud?" card can be reviewed on a cool Mac too.
        if let template = e.current {
            let demo = Engine(headless: true), a = Analyzer()
            for f in Demo.frames(template: template, count: 30) { demo.feed(f, findings: a.ingest(f)) }
            out("thermals-demo", height: 1300, engine: demo, VStack { ThermalPerf() })
        }
        // Trends: first with this headless engine's empty in-memory log (the "needs more days" states), then with
        // demo history and a demo battery session (the headless log is never persisted).
        out("trends-empty", height: 1300, TrendsPreview(log: e.dailyLog))
        e.dailyLog.replaceForDemo(days: Demo.trendDays(), charge: Demo.chargeStatus())
        out("trends", height: 2300, TrendsPreview(log: e.dailyLog))
        out("trends-90", height: 2300, TrendsPreview(log: e.dailyLog, days: 90))
        out("charge-drain", height: 400, ChargeDrainPanel(preview: Demo.chargeStatus()))
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
        // Checkup, Peripherals and the listening-ports panel read the real machine; their loaders run asynchronously,
        // so the run loop is spun until each has a result (Checkup waits on the black box and ~17 tools).
        CheckupModel.shared.run(engine: e)
        let until = Date().addingTimeInterval(30)
        while CheckupModel.shared.running && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        out("checkup", height: 2000, CheckupView())
        // The loaders are started and awaited here and handed to the views, since ImageRenderer doesn't run onAppear.
        func ready<T>(_ l: Loader<T>) -> Loader<T> {
            l.load(); let until = Date().addingTimeInterval(30)
            while l.value == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            return l
        }
        out("peripherals", height: 1500, PeripheralsView(loader: ready(Loader { Peripherals.collect() })))
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
        out("listening_ports",height: 420, ListeningPortsPanel(loader: ready(Loader { ListeningPorts.scan() })).frame(maxHeight: .infinity, alignment: .top))
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
