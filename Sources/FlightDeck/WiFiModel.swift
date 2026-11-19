// State behind the Wi-Fi page: the last nearby-network scan, the link history while the page is visible, the optional
// in-page scan timer, walk-test mode and the Location Services request. Nothing here runs while the page is hidden:
// `appear()` subscribes to the Engine's samples and `disappear()` cancels that and the timer. Scans happen only when
// the user presses Scan or turns on the timer, because a scan takes the radio off its channel for a moment.
// Scans and link history are memory only and are never written to disk.
import SwiftUI
import Combine
import CoreLocation
import FlightDeckCore

/// The link facts the page shows beside the history (the snapshot's WiFiInfo, or the demo's invented one).
struct WiFiLinkNow: Equatable {
    var ssid: String?
    var phy: String?
    var security: String?
    var point: WiFiLinkPoint
}

@MainActor
final class WiFiModel: ObservableObject {
    static let shared = WiFiModel()

    @Published private(set) var scan: WiFiScanResult?
    @Published private(set) var scanning = false
    @Published private(set) var scanError: String?
    @Published private(set) var history = WiFiLinkHistory()
    @Published private(set) var link: WiFiLinkNow?
    @Published private(set) var permission: WiFiPermission.Status = .notDetermined
    /// Rescan every `autoInterval` seconds while the page is visible. Off by default and not remembered across
    /// launches, so scanning never starts on its own.
    @Published var autoScan = false { didSet { if autoScan != oldValue { restartTimer() } } }
    @Published var walkTest = false
    /// Invented data only: no scanning, no real readings (`-demo YES` and the demo render).
    let demo: Bool
    static let autoInterval: TimeInterval = 45

    private var samples: AnyCancellable?
    private var timer: Task<Void, Never>?
    private var visible = false
    private var location: CLLocationManager?
    private let locationDelegate = LocationDelegate()

    init(demo: Bool? = nil) {
        let demo = demo ?? Demo.isEnabled
        self.demo = demo
        if demo { loadDemo() } else { permission = WiFiPermission.status() }
        locationDelegate.changed = { [weak self] in Task { @MainActor in self?.permission = WiFiPermission.status() } }
    }

    /// Off-screen renders and previews: fixed data, no subscriptions.
    init(preview scan: WiFiScanResult?, history: [WiFiLinkPoint], link: WiFiLinkNow?, permission: WiFiPermission.Status, demo: Bool) {
        self.demo = demo; self.scan = scan; self.link = link; self.permission = permission
        self.history.replace(history)
    }

    /// Whether the app bundle declares why it wants Location (without the Info.plist key macOS never prompts, e.g.
    /// when run with `swift run`).
    var canRequestLocation: Bool { Bundle.main.object(forInfoDictionaryKey: "NSLocationUsageDescription") != nil }

    func appear(_ engine: Engine) {
        visible = true
        guard !demo, samples == nil else { return }
        permission = WiFiPermission.status()
        // Seed with the Engine's recent history (the last couple of minutes), then follow its samples. These are the
        // readings the sampler already takes; nothing extra is read from CoreWLAN.
        for s in engine.frames.compactMap({ $0 }) { ingest(s) }
        if let s = engine.liveSnapshot { ingest(s) }
        samples = engine.$liveSnapshot.compactMap { $0 }.sink { [weak self] s in self?.ingest(s) }
        restartTimer()
    }

    func disappear() {
        visible = false
        samples?.cancel(); samples = nil
        timer?.cancel(); timer = nil
    }

    private func ingest(_ s: Snapshot) {
        var h = history
        if let w = s.wifi {
            let p = WiFiLinkPoint(w, time: s.time)
            h.add(p)
            let now = WiFiLinkNow(ssid: w.ssid, phy: w.phy, security: w.security, point: p)
            if now != link { link = now }
        } else {
            h.addAbsent(at: s.time)
            if link != nil { link = nil }
        }
        // Only publish real changes: most samples repeat the cached reading and would redraw the page for nothing.
        if h.points.count != history.points.count || h.drops.count != history.drops.count || h.points.last != history.points.last { history = h }
    }

    /// One scan off the main thread. Ignored while one is running, and in demo mode.
    func scanNow() {
        guard !demo, !scanning else { return }
        scanning = true; scanError = nil
        Task {
            let r = await Task.detached(priority: .userInitiated) { WiFiScanner.scan() }.value
            scanning = false
            switch r {
            case .success(let s): scan = s
            case .failure(let e): scanError = e.description
            }
            permission = WiFiPermission.status()
        }
    }

    private func restartTimer() {
        timer?.cancel(); timer = nil
        guard autoScan, visible, !demo else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.scanNow()
                try? await Task.sleep(for: .seconds(WiFiModel.autoInterval))
            }
        }
    }

    /// Asks macOS for Location permission. Only called from the page's button. The manager is kept so its delegate
    /// hears the answer.
    func requestLocation() {
        guard !demo else { return }
        let m = location ?? CLLocationManager()
        m.delegate = locationDelegate
        location = m
        m.requestWhenInUseAuthorization()
    }

    private func loadDemo() {
        let now = Date()
        scan = WiFiDemo.scan(at: now)
        history.replace(WiFiDemo.history(until: now), drops: [])
        link = history.points.last.map { WiFiLinkNow(ssid: WiFiDemo.ownSSID, phy: "802.11ax (Wi-Fi 6)", security: "WPA3", point: $0) }
        permission = .granted
    }
}

/// CLLocationManager wants an NSObject delegate; this one just forwards authorization changes.
final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var changed: (() -> Void)?
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { changed?() }
}
