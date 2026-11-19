// State behind the Restarts & Crashes page, and the launch check that raises its one-shot findings. All reading
// happens in FlightDeckCore (RestartsCollector) on a detached task: when the page appears, on Refresh, and once ~30 s
// after launch. Nothing polls.
import SwiftUI
import FlightDeckCore

@MainActor
final class RestartsModel: ObservableObject {
    /// FlightDeck's saved boot history (boots.json). One instance for the app, shared by the page and the launch check.
    nonisolated static let store = BootStore(dir: DailyLog.defaultDirectory)

    @Published private(set) var report: RestartsReport?
    @Published private(set) var loading = false
    /// Demo and preview models never read the machine.
    let fixed: Bool
    private let store: BootStore

    init(store: BootStore = RestartsModel.store) { self.store = store; fixed = false }
    /// A model showing a report that is already built (demo data, or a load finished before an off-screen render).
    init(preview: RestartsReport) { report = preview; store = BootStore(dir: nil); fixed = true }

    /// Reads every source, asking the unified log about recent boots it hasn't resolved yet (about a second each, at
    /// most RestartsCollector.maxQueries). `blackBox` supplies frames for "busiest after login".
    func load(blackBox: BlackBox?) async {
        guard !fixed, !loading else { return }
        loading = true; defer { loading = false }
        let store = self.store
        let frames = Self.frames(blackBox)
        report = await Task.detached(priority: .utility) { RestartsCollector.collect(store: store, queryLog: .recent, blackBox: frames) }.value
    }

    /// Reads black-box frames (coarse tier: every 10 s for 24 h) for the collector, off the main thread.
    nonisolated static func frames(_ blackBox: BlackBox?) -> (@Sendable (Date, Date) -> [Snapshot])? {
        guard let blackBox else { return nil }
        return { @Sendable from, to in blackBox.trace(.coarse, from: from, to: to)?.frames ?? [] }
    }

    /// Synchronous load for UIBench's off-screen renders (ImageRenderer never runs `.task`). Call before building views.
    static func loadedForRender(blackBox: BlackBox?) -> RestartsModel {
        let frames = Self.frames(blackBox)
        // Read-only: the saved history is loaded but a render never writes boots.json.
        let copy = BootStore(dir: DailyLog.defaultDirectory, readOnly: true)
        return RestartsModel(preview: RestartsCollector.collect(store: copy, queryLog: .recent, blackBox: frames))
    }

    /// Once per launch, ~30 s in (so it doesn't add to a login's busiest minute): one unified-log query for the current
    /// boot, then any unexpected shutdown or panic not announced before becomes a finding. Not in demo mode.
    static func launchCheck() {
        guard !Demo.isEnabled else { return }
        let store = Self.store
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(30))
            let found = RestartsCollector.launchCheck(store: store)
            if !found.isEmpty { RestartWatch.shared.add(found) }
        }
    }
}
