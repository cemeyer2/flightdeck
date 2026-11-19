// Destinations in the app: `DestinationService` owns the one live tracker (handed to the Engine's Sampler, never in
// demo mode or a headless engine) and its alert findings; `DestinationsModel` builds the page's report off the main
// thread and republishes it. Demo mode and UIBench use a preview model over invented days and an in-memory store.
import SwiftUI
import FlightDeckCore

/// The live tracker. Not main-actor: the Engine reads `findings` on its sampling queue.
enum DestinationService {
    static let lookupsKey = "destinationsReverseDNS"
    /// Reverse DNS is on unless the user turned it off (it asks the Mac's DNS server about each new remote IP).
    static var lookupsAllowed: Bool { UserDefaults.standard.object(forKey: lookupsKey) as? Bool ?? true }

    /// Created on first use. nil in demo mode (`-demo YES`): nothing is collected or written.
    static let tracker: DestinationTracker? = {
        guard !UserDefaults.standard.bool(forKey: "demo") else { return nil }
        let store = DestinationStore(dir: DestinationStore.defaultDirectory)
        store.prune()
        let t = DestinationTracker(store: store, namer: HostNamer())
        t.lookupsEnabled = lookupsAllowed
        return t
    }()

    /// Saves the open day at quit. Called once by the Engine (which also hands the tracker to its Sampler).
    static func start() {
        guard let tracker else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in tracker.flush() }
    }

    /// The opt-in "new destination" findings (Settings › Alerts); [] when off. Called on the Engine's sampling queue.
    static func findings(now: Date) -> [Finding] {
        guard let tracker else { return [] }
        let settings = DestinationAlertSettings.load()
        guard settings.enabled else { return [] }
        return DestinationFindings.findings(tracker.newContacts(since: now.addingTimeInterval(-2 * DestinationFindings.window)), settings: settings, now: now)
    }
}

@MainActor
final class DestinationsModel: ObservableObject {
    /// The app's model: the live tracker, or in demo mode invented days.
    static let shared: DestinationsModel = DestinationService.tracker.map { DestinationsModel(tracker: $0) }
        ?? DestinationsModel(preview: Demo.destinationDays(), known: Demo.destinationKnown())

    @Published private(set) var apps: [AppDestinations] = []
    /// Days with data among the last 30, and when counting began on the earliest of them.
    @Published private(set) var daysRecorded = 0
    @Published private(set) var since: Date?
    @Published private(set) var built: Date?
    let tracker: DestinationTracker?
    let store: DestinationStore
    /// True for the invented demo data: nothing here is about this Mac.
    let preview: Bool
    private var building = false
    private var lastRevision = -1

    init(tracker: DestinationTracker) {
        self.tracker = tracker; store = tracker.store ?? DestinationStore(dir: nil); preview = false
    }

    /// A model over fixed days (demo mode, UIBench). `demo` false is for a read-only render of this Mac's data.
    init(preview days: [DestinationDay], known: KnownDestinations, demo: Bool = true) {
        tracker = nil; preview = demo
        store = DestinationStore(preview: days, known: known)
        apps = DestinationReport.build(days: days, known: known, now: Date())
        daysRecorded = days.filter { $0.firstCounted != nil }.count
        since = days.compactMap(\.firstCounted).min()
        built = Date()
    }

    /// Rebuilds the report in the background (reads up to 30 day files; closed days are cached by the store).
    /// Skipped while a build is running or when nothing changed since the last one.
    func refresh() {
        guard let tracker, !building else { return }
        let rev = tracker.revision
        guard rev != lastRevision || built.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        building = true
        let store = self.store
        Task.detached(priority: .utility) {
            let now = Date()
            let today = tracker.today()
            let saved = store.days(from: now.addingTimeInterval(-Double(DestinationStore.retentionDays) * 86_400), to: now)
                .filter { $0.start != today.start }
            let days = saved + [today]
            let apps = DestinationReport.build(days: days, known: tracker.known(), now: now)
            let recorded = days.filter { $0.firstCounted != nil }
            await MainActor.run {
                self.apps = apps; self.daysRecorded = recorded.count; self.since = recorded.compactMap(\.firstCounted).min()
                self.built = now; self.building = false; self.lastRevision = rev
            }
        }
    }

    /// One app's destinations, for the process inspector (nil if it has none recorded).
    func app(_ key: String) -> AppDestinations? { apps.first { $0.id == key } }

    func clearHistory() {
        if let tracker { tracker.clear() } else { store.clear() }
        apps = []; daysRecorded = 0; since = nil
    }

    /// The live tracker's reverse-DNS switch (Settings).
    static func applyLookups() { DestinationService.tracker?.lookupsEnabled = DestinationService.lookupsAllowed }
}
