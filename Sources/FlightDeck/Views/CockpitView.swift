import SwiftUI
import FlightDeckCore
// The Summary page as a customizable cockpit: a slim header (layout picker, Ambient mode, Edit/Done) over the
// selected layout's instruments, placed by CockpitGridLayout. Edit mode (CockpitEditing.swift) adds a strip with a
// drag handle, size and remove controls above each instrument, and the "Add instrument" palette. Nothing animates.
//
// Off-screen renders (UIBench) can't draw AppKit controls (menus, text fields), so the header swaps those for
// look-alike labels when `\.offscreen` is set; the instruments themselves are the same in both paths.

struct CockpitView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @ObservedObject var model: CockpitModel
    @State private var confirmResetAll = false

    init(model: CockpitModel? = nil) { self.model = model ?? CockpitModel.shared }

    var body: some View {
        MaybeScroll {
            VStack(spacing: 12) {
                CockpitHeader(model: model, confirmResetAll: $confirmResetAll)
                if model.editing { AddInstrumentPalette(model: model) }
                CockpitGridLayout {
                    ForEach(model.current.slots) { slot in
                        Group {
                            if model.editing { EditableInstrument(model: model, slot: slot) } else { InstrumentView(slot: slot) }
                        }
                        .instrumentSize(slot.size)
                    }
                }
                if model.current.slots.isEmpty {
                    Text(model.editing ? "This layout is empty. Add instruments from the palette above."
                                       : "This layout is empty. Click Edit to add instruments.")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(p.dim).padding(.top, 40)
                }
            }
            .padding(16)
        }
        .confirmationDialog("Reset all cockpit layouts?", isPresented: $confirmResetAll) {
            Button("Reset All Layouts", role: .destructive) { model.store = CockpitStore.defaults() }
        } message: {
            Text("Your own layouts are deleted and the built-in ones (Default, Thermals, Network, Ambient) are restored.")
        }
    }
}

/// Small capsule button in the instrument-panel style; drawn by SwiftUI so it also renders off-screen.
struct CockpitButtonStyle: ButtonStyle {
    @Environment(\.palette) var p
    @Environment(\.isEnabled) var enabled
    var prominent = false
    func makeBody(configuration c: Configuration) -> some View {
        c.label
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(!enabled ? p.dim.opacity(0.5) : prominent ? Color.black : p.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(prominent ? p.accent.opacity(c.isPressed ? 0.7 : 1) : p.panel.opacity(c.isPressed ? 0.6 : 1)))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : p.panelBorder))
            .contentShape(Capsule())
    }
}

/// A pull-down menu, or (off-screen, where menus can't render) just its label drawn as a capsule.
struct CockpitMenu<Label: View, Content: View>: View {
    @Environment(\.offscreen) private var offscreen
    @Environment(\.palette) var p
    @ViewBuilder var label: Label
    @ViewBuilder var content: Content
    var body: some View {
        if offscreen {
            Button {} label: { HStack(spacing: 4) { label; Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) } }
                .buttonStyle(CockpitButtonStyle())
        } else {
            Menu { content } label: { label }.menuStyle(.borderlessButton).fixedSize()
        }
    }
}

/// Layout picker and its actions, the Ambient mode button, and Edit/Done. While editing, the layout's name is editable.
struct CockpitHeader: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @Environment(\.offscreen) private var offscreen
    @ObservedObject var model: CockpitModel
    @Binding var confirmResetAll: Bool

    var body: some View {
        HStack(spacing: 8) {
            if model.editing {
                Text("LAYOUT").font(.meterLabel).foregroundStyle(p.dim)
                if offscreen {
                    Text(model.current.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.text)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(p.accent.opacity(0.6)))
                } else {
                    TextField("Layout name", text: Binding(get: { model.current.name },
                                                           set: { n in model.edit { $0.name = n } }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(width: 200)
                }
                Button("Reset to Default") { model.edit { $0.reset() } }.buttonStyle(CockpitButtonStyle())
                    .help(model.current.preset == nil ? "Replace this layout's instruments with the Default ones"
                                                      : "Restore this layout's built-in instruments")
            } else {
                layoutMenu
            }
            Spacer()
            AmbientMenu(model: model)
            Button(model.editing ? "Done" : "Edit") { model.editing.toggle() }
                .buttonStyle(CockpitButtonStyle(prominent: model.editing))
                .keyboardShortcut("e", modifiers: [.command, .option])
                .help(model.editing ? "Leave edit mode" : "Arrange this layout's instruments (⌥⌘E)")
        }
    }

    var layoutMenu: some View {
        CockpitMenu {
            Label(model.current.name, systemImage: "rectangle.3.group").font(.system(size: 11, weight: .semibold, design: .monospaced))
        } content: {
            Picker("Layout", selection: Binding(get: { model.store.selected }, set: { model.store.selected = $0 })) {
                ForEach(model.store.layouts) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Duplicate Layout") { model.store.duplicateCurrent(); model.editing = true }
            Button("Reset “\(model.current.name)” to Default") { model.edit { $0.reset() } }
            Button("Delete “\(model.current.name)”") { model.store.deleteCurrent() }.disabled(model.store.layouts.count < 2)
            Divider()
            Button("Reset All Layouts…") { confirmResetAll = true }
        }
        .help("Choose a cockpit layout")
    }
}

/// Opens Ambient mode on a display, and chooses which layout its gauges come from.
struct AmbientMenu: View {
    @EnvironmentObject var e: Engine
    @ObservedObject var model: CockpitModel

    var body: some View {
        CockpitMenu {
            Label("Ambient", systemImage: "display").font(.system(size: 11, weight: .semibold, design: .monospaced))
        } content: {
            Button("Open Ambient Mode") { AmbientController.shared.open(engine: e) }
            Menu("Open on Display") {
                ForEach(AmbientController.displays(), id: \.id) { d in
                    Button(d.name) { AmbientController.shared.open(engine: e, displayID: d.id) }
                }
            }
            Divider()
            Picker("Gauges From", selection: Binding(get: { model.store.ambientLayout?.id }, set: { model.store.ambient = $0 })) {
                // Only offered once the built-in Ambient layout is gone (it is the default source while it exists).
                if model.store.ambientLayout == nil { Text("Standard Gauges").tag(UUID?.none) }
                ForEach(model.store.layouts) { Text($0.name).tag(Optional($0.id)) }
            }
        }
        .help("Full-screen instrument panel for a second display or an iPad (⌃⌘A)")
    }
}
