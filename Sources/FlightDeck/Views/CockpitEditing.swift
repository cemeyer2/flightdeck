import SwiftUI
import FlightDeckCore
// Cockpit edit mode: each instrument gets a strip above it (drag handle, name, size S/M/L, move earlier/later, remove)
// and a dashed outline, and an "Add instrument" palette lists every kind. No jiggling, no animation: edit mode is a
// static state the page switches into and out of.
//
// Reordering uses SwiftUI's own drag and drop (`draggable` / `dropDestination` carrying the slot's id as text), never
// an AppKit drag view, and is only attached on screen; the off-screen render shows the same strip and outline.

/// One instrument in edit mode. Its own controls stay clickable; the instrument underneath doesn't react to clicks.
struct EditableInstrument: View {
    @Environment(\.palette) var p
    @Environment(\.offscreen) private var offscreen
    @ObservedObject var model: CockpitModel
    var slot: InstrumentSlot
    /// True while something is dragged over this instrument: it's outlined in the accent colour as the drop spot.
    @State private var targeted = false

    var body: some View {
        let cell = VStack(spacing: 6) {
            strip
            InstrumentView(slot: slot).allowsHitTesting(false)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.accent.opacity(targeted ? 0.12 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(p.accent.opacity(targeted ? 0.9 : 0.45), style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [] : [5, 4])))
        if offscreen {
            cell
        } else {
            cell
                .draggable(slot.id.uuidString) { dragPreview }
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
                    model.edit { $0.move(id, onto: slot.id) }
                    return true
                } isTargeted: { targeted = $0 }
        }
    }

    /// Drag handle, name, size buttons, move buttons and remove.
    var strip: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.dim)
                .help("Drag to move")
            Image(systemName: slot.kind.symbol).font(.system(size: 11)).foregroundStyle(p.accent)
            Text(slot.kind.title.uppercased()).font(.meterLabel).foregroundStyle(p.text).lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(InstrumentSize.allCases) { s in
                    Button(s.letter) { model.edit { $0.setSize(slot.id, s) } }
                        .buttonStyle(SegmentStyle(selected: slot.size == s))
                        .help("\(s.title): " + (s == .small ? "one column" : s == .medium ? "two columns" : "the whole row"))
                }
            }
            iconButton("chevron.left", "Move earlier") { model.edit { $0.move(slot.id, by: -1) } }
            iconButton("chevron.right", "Move later") { model.edit { $0.move(slot.id, by: 1) } }
            iconButton("xmark", "Remove from this layout") { model.edit { $0.remove(slot.id) } }
        }
        .padding(.horizontal, 6)
    }

    func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 20, height: 18)
                .foregroundStyle(symbol == "xmark" ? p.crit : p.text)
                .background(RoundedRectangle(cornerRadius: 4).fill(p.panel))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(p.panelBorder))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    var dragPreview: some View {
        Label(slot.kind.title, systemImage: slot.kind.symbol)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(p.panel))
            .foregroundStyle(p.text)
    }
}

/// One segment of the S/M/L size control.
struct SegmentStyle: ButtonStyle {
    @Environment(\.palette) var p
    var selected: Bool
    func makeBody(configuration c: Configuration) -> some View {
        c.label
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .frame(width: 20, height: 18)
            .foregroundStyle(selected ? Color.black : p.dim)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? p.accent : p.panel.opacity(c.isPressed ? 0.6 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.clear : p.panelBorder))
            .contentShape(Rectangle())
    }
}

/// Every instrument kind; clicking one appends it to the layout at its default size. Kinds already in the layout are
/// ticked and disabled, so the palette also shows at a glance what's on the page. Dropping an instrument here moves
/// it to the end of the layout.
struct AddInstrumentPalette: View {
    @Environment(\.palette) var p
    @Environment(\.offscreen) private var offscreen
    @ObservedObject var model: CockpitModel

    var body: some View {
        let panel = Panel(title: "Add instrument", trailing: "drag to reorder · S M L sets the width · drop here to move to the end") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)], spacing: 6) {
                ForEach(InstrumentKind.allCases) { k in
                    let added = model.current.contains(k)
                    Button { model.edit { $0.add(k) } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: k.symbol).frame(width: 16).foregroundStyle(added ? p.dim : p.accent)
                            Text(k.title).lineLimit(1)
                            Spacer(minLength: 2)
                            Image(systemName: added ? "checkmark" : "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(p.dim)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(added ? p.dim : p.text)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(p.background.opacity(0.5)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(p.panelBorder))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(added)
                    .help(added ? "Already in this layout" : "Add \(k.title)")
                }
            }
        }
        if offscreen {
            panel
        } else {
            panel.dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first.flatMap(UUID.init(uuidString:)), let last = model.current.slots.last?.id else { return false }
                model.edit { $0.move(id, onto: last) }
                return true
            }
        }
    }
}
