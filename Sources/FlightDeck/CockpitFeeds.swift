// What the cockpit's page-digest instruments (Destinations, Restarts, Boot Time, Battery Health, Camera & Mic) read:
// reports the pages' own models already keep, cached here, refreshed rarely off the main thread and only while one of
// those instruments is on screen. Drawing an instrument never reads the disk, the log or the registry.
//
//   Destinations   DestinationsModel.shared's report; rebuilt off-main at most every 5 min while shown (the model
//                  also skips a rebuild when its tracker saw nothing new).
//   Restarts,      the report RestartsModel's launch check collects once, ~30 s after launch (and any later load of
//   Boot Time      the Restarts page). The cockpit never collects on its own: uptime comes from kern.boottime.
//   Battery Health a BatteryReport from the daily log's in-memory battery days, rebuilt off-main every 30 min while
//                  shown (no system_profiler, no pmset).
//   Camera & Mic   CameraMicModel.shared, which the watch updates on each device change; nothing is polled.
//
// Demo mode uses the invented data of each page (DemoRestarts, DemoBattery via DemoCharging, the demo models).
// Off-screen renders pass a preview instance through `\.cockpitFeeds`.
import SwiftUI
import FlightDeckCore

@MainActor
final class CockpitFeeds: ObservableObject {
    static let shared = CockpitFeeds()

    @Published private(set) var restarts: RestartsReport?
    @Published private(set) var battery: BatteryReport?
    private(set) var batteryBuilt: Date?
    /// Invented data only: nothing is loaded from this Mac.
    let fixed: Bool
    private let destinationsOverride: DestinationsModel?
    private let cameraMicOverride: CameraMicModel?
    private var batteryLoading = false
    /// Built digests, reused until their source changes (Views/CockpitFeedReadings.swift).
    let digests = FeedDigestCache()

    static let destinationsInterval: TimeInterval = 300
    static let batteryInterval: TimeInterval = 1800

    private init() {
        fixed = Demo.isEnabled
        destinationsOverride = nil; cameraMicOverride = nil
        if fixed {
            restarts = DemoRestarts.report()
            battery = DemoCharging.inputs().report
            batteryBuilt = Date()
        }
    }

    /// A preview with everything already loaded (UIBench renders: loads must finish before the view is built).
    init(preview restarts: RestartsReport?, battery: BatteryReport?, destinations: DestinationsModel, cameraMic: CameraMicModel) {
        fixed = true
        self.restarts = restarts; self.battery = battery; batteryBuilt = Date()
        destinationsOverride = destinations; cameraMicOverride = cameraMic
    }

    /// Created on first use, so a cockpit without these instruments never builds them.
    var destinations: DestinationsModel { destinationsOverride ?? .shared }
    var cameraMic: CameraMicModel { cameraMicOverride ?? .shared }

    /// The launch check (or a Restarts page load) finished.
    func restartsLoaded(_ r: RestartsReport) { if !fixed { restarts = r } }

    /// Keeps one instrument's source fresh while it is on screen; returns when the view's task is cancelled.
    func keepFresh(_ kind: InstrumentKind, engine: Engine) async {
        guard !fixed else { return }
        switch kind {
        case .destinations:
            while !Task.isCancelled {
                destinations.refresh()
                try? await Task.sleep(for: .seconds(Self.destinationsInterval))
            }
        case .batteryHealth:
            while !Task.isCancelled {
                let loaded = await loadBattery(engine: engine)
                try? await Task.sleep(for: .seconds(loaded ? Self.batteryInterval : 5))   // first sample not in yet: retry soon
            }
        default:
            return
        }
    }

    /// Rebuilds the battery report when it is older than `batteryInterval`. False when there's no sample yet.
    private func loadBattery(engine: Engine) async -> Bool {
        if let b = batteryBuilt, Date().timeIntervalSince(b) < Self.batteryInterval - 1 { return true }
        guard let s = engine.current else { return false }
        guard !batteryLoading else { return true }
        batteryLoading = true; defer { batteryLoading = false }
        let b = s.power.battery, facts = s.power.charging?.facts, log = engine.dailyLog
        battery = await Task.detached(priority: .utility) {
            let h = b == nil ? nil : log.batteryHistory()
            return BatteryReport(battery: b, facts: facts, condition: nil, history: h?.days ?? [], lifetime: h?.lifetime)
        }.value
        batteryBuilt = Date()
        return true
    }
}

private struct CockpitFeedsKey: EnvironmentKey { static let defaultValue: CockpitFeeds? = nil }

extension EnvironmentValues {
    /// The feeds the cockpit's page-digest instruments read; nil means `CockpitFeeds.shared`.
    var cockpitFeeds: CockpitFeeds? {
        get { self[CockpitFeedsKey.self] }
        set { self[CockpitFeedsKey.self] = newValue }
    }
}
