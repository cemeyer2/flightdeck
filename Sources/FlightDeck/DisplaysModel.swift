// State behind the Displays page. Reading happens in FlightDeckCore (DisplayCollector) on a detached task, with
// NSScreen read here on the main thread first: when the page appears, when macOS reports a display change while
// it is visible (didChangeScreenParametersNotification), and on Refresh. Nothing polls.
import SwiftUI
import FlightDeckCore

@MainActor
final class DisplaysModel: ObservableObject {
    @Published private(set) var report: DisplaysReport?
    @Published private(set) var loading = false
    /// Demo and preview models never read the machine.
    let fixed: Bool

    init() { fixed = false }
    /// A model showing a report that is already built (demo data, or a load finished before an off-screen render).
    init(preview: DisplaysReport) { report = preview; fixed = true }

    func load() async {
        guard !fixed, !loading else { return }
        loading = true; defer { loading = false }
        let screens = DisplayScreens.read()
        let history = DisplayHistory.shared.all
        let r = await Task.detached(priority: .utility) { DisplayCollector.collect(screens: screens, history: history) }.value
        DisplayHistory.shared.learnNames(Dictionary(r.displays.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        report = r
    }

    /// Synchronous load for UIBench's off-screen renders (ImageRenderer never runs `.task`). Call before building views.
    static func loadedForRender() -> DisplaysModel {
        DisplaysModel(preview: DisplayCollector.collect(screens: DisplayScreens.read(), history: DisplayHistory.shared.all))
    }
}
