// UIBench's off-screen renders of the cockpit and Ambient mode (kept here so UIBench.swift only gains a few lines).
// Every render uses an unsaved preview CockpitModel, so rendering never writes the user's layouts.
import SwiftUI
import FlightDeckCore

@MainActor
extension UIBench {
    /// The cockpit renders: the default layout (what "summary" shows anyone who hasn't edited it), an edited layout
    /// using every size and most of the new instruments, the same in edit mode, and Ambient mode at the proportions of
    /// a typical external display.
    static func cockpitRenders() -> [(name: String, width: CGFloat, height: CGFloat, view: AnyView)] {
        [("cockpit-default", 1100, 1500, AnyView(CockpitView(model: CockpitModel(preview: .defaults())))),
         ("cockpit-edited", 1100, 2300, AnyView(CockpitView(model: CockpitModel(preview: editedCockpit())))),
         ("cockpit-edit", 1100, 2900, AnyView(CockpitView(model: CockpitModel(preview: editedCockpit(), editing: true)))),
         ("ambient", 1600, 1000, AnyView(ambientPreview()))]
    }

    /// Ambient mode with the built-in Ambient layout, at a fixed time (the render has no TimelineView ticks).
    static func ambientPreview() -> some View {
        AmbientView(model: CockpitModel(preview: .defaults()), fixedNow: Date())
    }

    /// A cockpit layout exercising all three sizes and the instruments added with the cockpit.
    static func editedCockpit() -> CockpitStore {
        var s = CockpitStore.defaults()
        s.editCurrent { l in
            l.name = "Mixed"
            l.slots = [InstrumentSlot(.annunciator, .large), InstrumentSlot(.cpu, .medium), InstrumentSlot(.clock, .small),
                       InstrumentSlot(.cpuCores, .large), InstrumentSlot(.memoryPressure, .small), InstrumentSlot(.swap, .small),
                       InstrumentSlot(.fans, .small), InstrumentSlot(.battery, .small), InstrumentSlot(.wifi, .medium),
                       InstrumentSlot(.stressMap, .medium), InstrumentSlot(.thermals, .small), InstrumentSlot(.findings, .large)]
        }
        return s
    }
}
