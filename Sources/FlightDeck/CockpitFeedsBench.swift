// UIBench renders of the page-digest instruments (Destinations, Restarts, Boot Time, Battery Health, Camera & Mic):
// a cockpit and Ambient mode over the invented demo data, then the same over this Mac's data, read-only (saved
// destinations, camera/mic history and boot history are only read; the battery report comes from the daily log).
// Every feed is loaded before the views are built, since ImageRenderer never runs `.task`.
import SwiftUI
import FlightDeckCore

@MainActor
extension UIBench {
    static let feedKinds: [InstrumentKind] = [.destinations, .restarts, .bootTime, .batteryHealth, .cameraMic]

    /// Invented data only (what `-demo YES` shows).
    static func demoFeeds(now: Date = Date()) -> CockpitFeeds {
        CockpitFeeds(preview: DemoRestarts.report(now: now), battery: DemoCharging.inputs(now: now).report,
                     destinations: DestinationsModel(preview: Demo.destinationDays(), known: Demo.destinationKnown()),
                     cameraMic: CameraMicModel(preview: DemoCameraMic.sessions(now: now), live: DemoCameraMic.live(now: now)))
    }

    /// This Mac's data, read-only. `restarts` is the report UIBench already collected for the Restarts page render.
    static func liveFeeds(engine e: Engine, restarts: RestartsReport?) -> CockpitFeeds {
        let now = Date()
        let dstore = DestinationStore(dir: DailyLog.defaultDirectory.appendingPathComponent("Destinations"), readOnly: true)
        let days = dstore.days(from: now.addingTimeInterval(-Double(DestinationStore.retentionDays) * 86_400), to: now)
        let dest = DestinationsModel(preview: days, known: dstore.loadKnown() ?? KnownDestinations(), demo: false)
        let cm = CameraMicModel(preview: CameraMicStore(dir: DailyLog.defaultDirectory, readOnly: true).sessions(),
                                live: CameraMicWatch.reading(), demo: false)
        let b = e.current?.power.battery, facts = e.current?.power.charging?.facts
        let h = b == nil ? nil : DailyLog(dir: DailyLog.defaultDirectory).batteryHistory()
        let battery = BatteryReport(battery: b, facts: facts, condition: nil, history: h?.days ?? [], lifetime: h?.lifetime)
        return CockpitFeeds(preview: restarts, battery: battery, destinations: dest, cameraMic: cm)
    }

    /// A layout with the page digests at each size, beside two classic gauges for comparison.
    static func feedsCockpit() -> CockpitStore {
        var s = CockpitStore.defaults()
        s.editCurrent { l in
            l.name = "Pages"
            l.slots = [InstrumentSlot(.cpu, .small)] + feedKinds.map { InstrumentSlot($0, .small) }
                + [InstrumentSlot(.destinations, .medium), InstrumentSlot(.batteryHealth, .small),
                   InstrumentSlot(.cameraMic, .medium), InstrumentSlot(.bootTime, .small), InstrumentSlot(.restarts, .large)]
        }
        return s
    }

    /// Ambient mode with the five page digests and three classic gauges.
    static func feedsAmbient() -> CockpitStore {
        var s = CockpitStore.defaults()
        s.editCurrent { l in l.slots = ([.cpu, .memory, .thermals] + feedKinds).map { InstrumentSlot($0, .small) } }
        s.ambient = s.selected
        return s
    }

    static func feedRenders(_ feeds: CockpitFeeds, suffix: String) -> [(name: String, width: CGFloat, height: CGFloat, view: AnyView)] {
        [("cockpit-pages" + suffix, 1100, 1500,
          AnyView(CockpitView(model: CockpitModel(preview: feedsCockpit())).environment(\.cockpitFeeds, feeds))),
         ("ambient-pages" + suffix, 1600, 1000,
          AnyView(AmbientView(model: CockpitModel(preview: feedsAmbient()), fixedNow: Date()).environment(\.cockpitFeeds, feeds)))]
    }
}
