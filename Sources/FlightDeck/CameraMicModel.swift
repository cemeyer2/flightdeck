// Camera & Mic in the app: `CameraMicService` owns the one live watch (started by the Engine, never in demo mode or a
// headless engine) and hands its alert findings to the Engine's sampling loop; `CameraMicModel` republishes the
// watch's state on the main actor for the page and the menu bar panel. Demo mode and UIBench use a preview model
// with invented sessions, an in-memory store and no listeners.
import SwiftUI
import FlightDeckCore

/// The live watch. Not main-actor: the Engine reads `findings` on its sampling queue.
enum CameraMicService {
    /// Created on first use. nil in demo mode (`-demo YES`), so no listener is ever registered and nothing is written.
    static let watch: CameraMicWatch? = UserDefaults.standard.bool(forKey: "demo")
        ? nil : CameraMicWatch(store: CameraMicStore(dir: DailyLog.defaultDirectory))

    /// Starts listening (idempotent) and closes open sessions at quit, so their end is recorded as "at least until".
    static func start() {
        guard let watch else { return }
        watch.onChange = { Task { @MainActor in CameraMicModel.shared.refresh() } }
        watch.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in watch.stop() }
    }

    /// The opt-in alert findings (Settings › Alerts); [] when both are off. Called on the Engine's sampling queue.
    static func findings(now: Date) -> [Finding] {
        guard let watch else { return [] }
        let settings = CameraMicAlertSettings.load()
        return settings.any ? watch.findings(settings: settings, now: now) : []
    }
}

@MainActor
final class CameraMicModel: ObservableObject {
    /// The app's model: the live watch, or in demo mode the invented sessions.
    static let shared: CameraMicModel = CameraMicService.watch.map { CameraMicModel(watch: $0) }
        ?? CameraMicModel(preview: DemoCameraMic.sessions(now: Date()), live: DemoCameraMic.live(now: Date()))

    @Published private(set) var live = CameraMicLive()
    /// All kept sessions, oldest first.
    @Published private(set) var sessions: [SensorSession] = []
    /// "kind|appKey" → first seen.
    @Published private(set) var firstSeen: [String: Date] = [:]
    let watch: CameraMicWatch?
    let store: CameraMicStore
    /// True for the invented demo data (and UIBench previews): nothing here is about this Mac.
    let preview: Bool
    private var revision = -1

    init(watch: CameraMicWatch) {
        self.watch = watch; store = watch.store; preview = false
        refresh()
    }

    /// A model with no watch. `demo` marks invented data; false is for UIBench's read-only render of this Mac's history.
    init(preview sessions: [SensorSession], live: CameraMicLive, demo: Bool = true) {
        watch = nil; preview = demo
        let known = Dictionary(sessions.compactMap { s in s.app.map { (CameraMicTracker.knownKey(s.kind, $0), s.start) } }, uniquingKeysWith: min)
        store = CameraMicStore(preview: sessions, known: known)
        var live = live
        live.open = sessions.filter(\.isOpen)   // the same session values as the history, so ids match
        self.live = live
        refresh()
    }

    /// Re-reads the watch (after it reported a change). The history is copied only when it changed.
    func refresh() {
        if let watch { live = watch.live }
        guard store.revision != revision else { return }
        revision = store.revision
        sessions = store.sessions(); firstSeen = store.firstSeen
    }

    func clearHistory() {
        if let watch { watch.clearHistory() } else { store.clear(); refresh() }
    }

    /// The open session of each kind, for the menu bar panel and the page's live cards.
    func open(_ k: SensorKind) -> [SensorSession] { live.open.filter { $0.kind == k } }
}
