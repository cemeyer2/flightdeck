// Ambient mode's window: a separate full-screen window on a chosen display (a second monitor, or an iPad via
// Sidecar, which macOS presents as an ordinary NSScreen) hosting AmbientView. Built in AppKit rather than as a SwiftUI
// scene because it has to be placed on a specific screen before entering full screen, close on Esc, and hide the
// cursor, none of which SwiftUI's Window scene exposes. Opened from View › Ambient Mode (⌃⌘A) and the Summary page.
import SwiftUI
import AppKit
import FlightDeckCore

@MainActor
final class AmbientController {
    static let shared = AmbientController()
    private var window: AmbientWindow?
    private var cursorTimer: Timer?
    private var lastMouse = NSPoint.zero
    /// Display last used, by CGDirectDisplayID; reused the next time when that display is still connected.
    private var savedDisplay: Int {
        get { UserDefaults.standard.integer(forKey: "ambientDisplay") }
        set { UserDefaults.standard.set(newValue, forKey: "ambientDisplay") }
    }

    /// Connected displays, for the "Open on Display" menus.
    static func displays() -> [(id: Int, name: String)] {
        NSScreen.screens.map { (Self.displayID($0), $0.localizedName) }
    }

    static func displayID(_ s: NSScreen) -> Int {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }

    /// The display to use: the one asked for, else the last one used, else a display other than the one with the main
    /// window (the whole point is a second screen), else the main screen.
    private func screen(for id: Int?) -> NSScreen? {
        let all = NSScreen.screens
        if let id, let s = all.first(where: { Self.displayID($0) == id }) { return s }
        if let s = all.first(where: { Self.displayID($0) == savedDisplay }) { return s }
        let mainWindowScreen = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.screen ?? NSScreen.main
        return all.first { $0 != mainWindowScreen } ?? NSScreen.main
    }

    var isOpen: Bool { window != nil }

    /// Opens Ambient mode, or brings it forward if it's already open. Asking for a different display closes it and opens
    /// a new window there, which is simpler and more reliable than moving a full-screen window between Spaces.
    func open(engine: Engine, displayID: Int? = nil) {
        if let w = window {
            if displayID == nil || w.screen.map(Self.displayID) == displayID { w.makeKeyAndOrderFront(nil); return }
            close()
        }
        guard let screen = screen(for: displayID) else { return }
        savedDisplay = Self.displayID(screen)
        let w = AmbientWindow(contentRect: screen.frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false, screen: screen)
        w.title = "FlightDeck Ambient"
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenPrimary, .managed]
        w.contentView = NSHostingView(rootView: AmbientRoot(engine: engine))
        w.onClose = { [weak self] in self?.didClose() }
        w.setFrame(screen.frame, display: false)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // Full screen after the window is on its display, so macOS creates the full-screen Space there.
        DispatchQueue.main.async { if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) } }
        startCursorHiding()
    }

    func toggle(engine: Engine) { isOpen ? close() : open(engine: engine) }

    func close() { window?.close() }

    private func didClose() {
        cursorTimer?.invalidate(); cursorTimer = nil
        window = nil
    }

    /// Hides the pointer once it has rested over the Ambient window for a few seconds; moving the mouse shows it again
    /// (`setHiddenUntilMouseMoves`). A 3 s timer is all this costs, and it only runs while Ambient mode is open.
    private func startCursorHiding() {
        cursorTimer?.invalidate()
        lastMouse = NSEvent.mouseLocation
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let w = self.window else { return }
                let m = NSEvent.mouseLocation
                if m == self.lastMouse && w.frame.contains(m) && w.isKeyWindow { NSCursor.setHiddenUntilMouseMoves(true) }
                self.lastMouse = m
            }
        }
    }
}

/// The Ambient window: Esc (cancelOperation) closes it, which also leaves its full-screen Space.
final class AmbientWindow: NSWindow {
    var onClose: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }   // 53 = Esc, if nothing sent cancelOperation
    }
    override func close() {
        super.close()
        onClose?(); onClose = nil
    }
}

/// Root of the hosting view: applies the user's theme (live, so changing it in Settings reaches Ambient too).
struct AmbientRoot: View {
    @ObservedObject var engine: Engine
    @AppStorage("theme") private var theme: ThemeID = .dark
    var body: some View {
        AmbientView(model: CockpitModel.shared).environmentObject(engine).themed(theme)
    }
}

/// View › Ambient Mode (⌃⌘A) and View › Ambient Mode on Display, as their own `.commands` block so the existing menus
/// stay untouched.
struct AmbientCommands: Commands {
    var engine: Engine
    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Ambient Mode") { AmbientController.shared.toggle(engine: engine) }
                .keyboardShortcut("a", modifiers: [.control, .command])
            Menu("Ambient Mode on Display") {
                ForEach(AmbientController.displays(), id: \.id) { d in
                    Button(d.name) { AmbientController.shared.open(engine: engine, displayID: d.id) }
                }
            }
            Divider()
        }
    }
}
