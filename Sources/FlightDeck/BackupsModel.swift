// Backups in the app. `BackupService` is the background check: every 15 minutes it reads Time Machine's settings
// file and `tmutil status`/`destinationinfo` (milliseconds, nothing mounted), and every 6 hours also backupd's new
// log messages (one `log show` over the hours since the last read, a second or two), then updates the gap finding
// and the page's model. Nothing runs in demo mode. The page also refreshes when it opens (reading the log if the last
// read is over 15 minutes old) and, while a backup is running and the page is open, once a minute for progress.
import SwiftUI
import FlightDeckCore

enum BackupService {
    /// FlightDeck's saved backup history. nil in demo mode: nothing is read or written.
    static let store: BackupStore? = UserDefaults.standard.bool(forKey: "demo") ? nil : BackupStore(dir: BackupStore.defaultDirectory)
    static let checkInterval: TimeInterval = 15 * 60
    static let logInterval: TimeInterval = 6 * 3600
    private static let queue = DispatchQueue(label: "flightdeck.backups", qos: .utility)
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    /// Starts the 15-minute check, the first one a minute after launch (out of the way of login). Called by the Engine.
    static func start() {
        guard let store, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: checkInterval, leeway: .seconds(60))
        t.setEventHandler {
            let scan = Date().timeIntervalSince(store.logScannedTo ?? .distantPast) > logInterval
            publish(BackupsCollector.collect(store: store, scanLog: scan))
        }
        t.resume(); timer = t
    }

    /// Hands a fresh report to the gap finding and the page.
    static func publish(_ r: BackupsReport) {
        BackupWatch.shared.set(BackupFindings.evaluate(r))
        Task { @MainActor in BackupsModel.shared.received(r) }
    }
}

@MainActor
final class BackupsModel: ObservableObject {
    /// The app's model: live, or in demo mode the invented history.
    static let shared: BackupsModel = BackupService.store.map { BackupsModel(store: $0) } ?? BackupsModel(preview: DemoBackups.report())

    @Published private(set) var report: BackupsReport?
    @Published private(set) var loading = false
    private(set) var loaded: Date?
    /// Demo and preview models never read the machine.
    let fixed: Bool
    private let store: BackupStore

    init(store: BackupStore) { self.store = store; fixed = false }
    init(preview: BackupsReport) { report = preview; store = BackupStore(dir: nil); fixed = true; loaded = Date() }

    func received(_ r: BackupsReport) { guard !fixed else { return }; report = r; loaded = Date() }

    /// `scanLog`: also read backupd's new log messages (a second or two of `log show`).
    func load(scanLog: Bool) async {
        guard !fixed, !loading else { return }
        loading = true; defer { loading = false }
        let store = self.store
        let r = await Task.detached(priority: .utility) { BackupsCollector.collect(store: store, scanLog: scanLog) }.value
        BackupWatch.shared.set(BackupFindings.evaluate(r))
        report = r; loaded = Date()
    }

    /// Page opened: refresh, reading the log if the last read is over 15 minutes old.
    func pageOpened() async {
        let stale = Date().timeIntervalSince(store.logScannedTo ?? .distantPast) > 15 * 60
        if report == nil || stale || Date().timeIntervalSince(loaded ?? .distantPast) > 60 { await load(scanLog: stale) }
    }

    /// While the page is open and a backup runs, progress is re-read every minute (tmutil and the plist only).
    func followProgress() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if report?.state == .backingUp { await load(scanLog: false) }
        }
    }

    /// Synchronous load for UIBench's off-screen renders: reads this Mac but never writes the saved history.
    static func loadedForRender() -> BackupsModel {
        let copy = BackupStore(dir: BackupStore.defaultDirectory, readOnly: true)
        return BackupsModel(preview: BackupsCollector.collect(store: copy, scanLog: true))
    }
}
