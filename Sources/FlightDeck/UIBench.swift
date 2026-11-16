import SwiftUI
import FlightDeckCore

/// `FlightDeck --bench-ui [renders]`: renders each main view off-screen with real data and reports the cost
/// per frame, so UI overhead can be measured without opening a window.
@MainActor
enum UIBench {
    /// Writes a 2x PNG of each main view (for visual review without opening a window).
    static func renderViews(to dir: String) -> Never {
        let e = Engine(headless: true)
        let sampler = Sampler(); let analyzer = Analyzer()
        _ = sampler.sample()
        for _ in 0..<40 { Thread.sleep(forTimeInterval: 0.25); let s = sampler.sample(); e.feed(s, findings: analyzer.ingest(s)) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = Palette.of(.dark)
        func out<V: View>(_ name: String, height: CGFloat = 1500, _ v: V) {
            let r = ImageRenderer(content: v.environmentObject(e).environment(\.palette, p).environment(\.colorScheme, .dark).environment(\.offscreen, true)
                .padding(16).frame(width: 1100, height: height, alignment: .top).background(p.background))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")); print("wrote \(name).png")
            }
        }
        out("summary", SummaryView())
        out("flightlog", FlightLogView())
        out("cpu", VStack { CPUPerf() })
        out("memory", height: 1900, VStack { MemoryPerf() })
        out("gpu", height: 2200, VStack { GPUPerf() })
        out("thermals", VStack { ThermalPerf() })
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
        if let me = e.current?.processes.first(where: { $0.pid == getpid() }) {
            let model = InspectorModel(identity: me.identity, engine: e)
            for _ in 0..<2 {   // let the background detail loads finish (two, so rates exist)
                RunLoop.main.run(until: Date().addingTimeInterval(1.5)); model.refreshDetails()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            out("inspector", height: 1700, InspectorView(model: model))
        }
        exit(0)
    }

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
        let g = e.current!
        bench("· aggregate x1", Text("\(AppUsage.aggregate(g.processes).count)"))
        bench("· HistoryGraph", HistoryGraph(traces: [GraphTrace(name: "c", values: e.series { $0.cpu.total.value }, color: .blue)], maxValue: 100).frame(height: 200))
        bench("Menu bar panel", MenuBarPanel())
        bench("Dock-size label", MenuBarLabel())
        exit(0)
    }
}
