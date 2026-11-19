// UIBench renders of the Destinations page: the invented demo data (all, searched, flagged-only), the inspector panel
// and settings, then this Mac's live destinations from ~12 s of real nettop samples through an in-memory tracker
// (nothing is written; reverse DNS runs for real). Every model is finished before any view is built (see UIBench.ready).
import SwiftUI
import FlightDeckCore

extension UIBench {
    static func destinationRenders(template: ProcessSample?) -> [(name: String, width: CGFloat, height: CGFloat, view: AnyView)] {
        let demo = DestinationsModel(preview: Demo.destinationDays(), known: Demo.destinationKnown())
        // Live: a private Sampler and tracker, in memory only, so the user's saved history is never touched.
        let tracker = DestinationTracker(store: nil, namer: HostNamer())
        let sampler = Sampler(); sampler.destinations = tracker
        for _ in 0..<13 { _ = sampler.sample(); Thread.sleep(forTimeInterval: 1) }
        RunLoop.main.run(until: Date().addingTimeInterval(4))   // let reverse-DNS answers arrive
        let live = DestinationsModel(preview: [tracker.today()], known: tracker.known(), demo: false)
        var out: [(name: String, width: CGFloat, height: CGFloat, view: AnyView)] = [
            ("destinations-demo", 1200, 2300, AnyView(DestinationsView(model: demo, range: .week))),
            ("destinations-demo-search", 1200, 900, AnyView(DestinationsView(model: demo, range: .month, query: "slack"))),
            ("destinations-settings", 700, 260, AnyView(VStack(alignment: .leading) { DestinationAlertsSection() })),
            ("destinations", 1200, 2300, AnyView(DestinationsView(model: live, range: .today))),
        ]
        // The inspector panel for a process of the demo's Slack: a real sample of this Mac (the core's sample type
        // can't be built outside it), renamed and re-pathed as Demo.swift does.
        if let slack = demo.apps.first(where: { $0.name == "Slack" }), var p = template {
            p.name = "Slack"; p.path = slack.id + "/Contents/MacOS/Slack"
            out.append(("destinations-inspector", 1000, 420, AnyView(DestinationsInspectorPanel(process: p, model: demo))))
        }
        return out
    }
}
