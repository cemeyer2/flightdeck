import SwiftUI
import FlightdeckCore

/// `Flightdeck --bench-ui [renders]`: renders each main view off-screen with real data and reports the cost
/// per frame, so UI overhead can be measured without opening a window.
@MainActor
enum UIBench {
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
            let content = v.environmentObject(e).environment(\.palette, p).frame(width: 1100, height: 1400)
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
