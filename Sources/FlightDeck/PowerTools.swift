// Glue for the power-user tools: the command palette (⌘K), diagnostic capture, and "sample stacks" requests sent to an
// inspector window. `PowerTools.shared` holds the little UI state these need, so menus, the palette and windows can
// reach each other without adding more published state to the Engine (every Engine publish re-evaluates every view).
import SwiftUI
import FlightDeckCore

@MainActor
final class PowerTools: ObservableObject {
    static let shared = PowerTools()
    /// The palette overlay in the main window.
    @Published var paletteVisible = false
    /// The Capture Diagnostics sheet in the main window.
    @Published var captureVisible = false
    /// Set by the palette's "Sample Stacks" action. The inspector window for this identity switches to its Stacks tab,
    /// starts a 3 s sample and clears the request (see InspectorView), so the inspector's own sampling code is reused.
    @Published var stackRequest: ProcessIdentity?

    /// Diagnostic capture runs real tools on this Mac's processes and logs, so it is unavailable in demo mode.
    static var captureAvailable: Bool { !Demo.isEnabled }

    /// Brings the main window forward and opens the palette there.
    func showPalette() {
        AppActions.showMain()
        paletteVisible = true
    }

    func showCapture() {
        guard Self.captureAvailable else { return }
        paletteVisible = false
        AppActions.showMain()
        captureVisible = true
    }
}

/// Menu items for the power tools, added as their own `.commands` block so the existing menus stay untouched:
/// View › Command Palette… (⌘K) and Help › Capture Diagnostics….
struct PowerToolsCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Command Palette…") { PowerTools.shared.showPalette() }.keyboardShortcut("k", modifiers: .command)
            Divider()
        }
        CommandGroup(after: .help) {
            Divider()
            Button("Capture Diagnostics…") { PowerTools.shared.showCapture() }.disabled(!PowerTools.captureAvailable)
        }
    }
}

/// Attached to the main window's content: hosts the palette overlay and the diagnostic capture sheet.
struct PowerToolsOverlay: ViewModifier {
    @ObservedObject var tools = PowerTools.shared
    @EnvironmentObject var engine: Engine
    @Environment(\.palette) var p
    func body(content: Content) -> some View {
        content
            .overlay {
                if tools.paletteVisible {
                    CommandPaletteView(engine: engine).environment(\.palette, p)
                }
            }
            .sheet(isPresented: $tools.captureVisible) {
                DiagnosticCaptureView().environmentObject(engine).environment(\.palette, p)
            }
    }
}
