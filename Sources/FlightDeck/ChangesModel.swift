// What Changed in the app. `ChangeService` owns the one live store and the background check: ~90 s after launch, then
// every 15 minutes, on a detached utility task (a check takes about a second: launchd folders and two launchctl
// calls, kmutil, systemextensionsctl, profiles, the Applications folders and Homebrew listings). Opening the page or
// pressing Check Now runs one too (at most once a minute). Notable changes become findings through ChangeWatch.
// Nothing runs in demo mode or a headless engine.
import SwiftUI
import FlightDeckCore

enum ChangeService {
    static let interval: TimeInterval = 15 * 60
    /// nil in demo mode (`-demo YES`): nothing is read or written.
    static let store: ChangeStore? = UserDefaults.standard.bool(forKey: "demo") ? nil : ChangeStore(dir: ChangeStore.defaultDirectory)
    /// Posted (on the main queue) after every check, so an open page shows the result.
    static let didCheck = Notification.Name("FlightDeckChangesChecked")
    private static let started = NSLock()
    nonisolated(unsafe) private static var running = false

    /// Starts the background loop once. Called by the Engine.
    static func start() {
        started.lock(); defer { started.unlock() }
        guard let store, !running else { return }
        running = true
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(90))   // after the launch checks, so it doesn't add to a login's busy minute
            while !Task.isCancelled {
                check(store)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// One check: read, compare, save, raise findings for notable changes. Blocking.
    @discardableResult
    static func check(_ store: ChangeStore) -> [ChangeEvent]? {
        guard let events = store.check() else { return nil }
        let f = ChangeFindings.findings(events)
        if !f.isEmpty { ChangeWatch.shared.add(f) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: didCheck, object: nil) }
        return events
    }
}

@MainActor
final class ChangesModel: ObservableObject {
    @Published private(set) var report: ChangesReport?
    @Published private(set) var checking = false
    /// Demo and preview models never read the machine.
    let fixed: Bool
    let demo: Bool
    private let store: ChangeStore?

    init() { store = ChangeService.store; fixed = store == nil; demo = false; report = store?.report }
    /// A model showing a report that is already built (demo data, or this Mac's saved log for an off-screen render).
    init(preview: ChangesReport, demo: Bool) { report = preview; store = nil; fixed = true; self.demo = demo }

    /// The saved log as it is now (cheap: a copy from memory).
    func reload() { if let store { report = store.report } }

    /// Runs a check unless one ran in the last minute (`force` for Check Now), then shows the result.
    func check(force: Bool = false) async {
        guard let store, !checking else { return }
        if !force, let last = store.report.lastCheck, Date().timeIntervalSince(last) < 60 { reload(); return }
        checking = true; defer { checking = false }
        _ = await Task.detached(priority: .utility) { ChangeService.check(store) }.value
        reload()
    }

    /// This Mac's saved log for UIBench, read-only, with one inventory taken in memory (nothing is written).
    static func savedForRender() -> ChangesModel {
        let store = ChangeStore(dir: ChangeStore.defaultDirectory, readOnly: true)
        _ = store.check()
        return ChangesModel(preview: store.report, demo: false)
    }
}
