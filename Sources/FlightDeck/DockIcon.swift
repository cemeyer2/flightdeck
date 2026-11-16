// The live Dock tile. Engine.ingest feeds every live sample to DockIconController, which keeps a short CPU history and
// redraws a DockTileView installed as the Dock tile's content view. The Dock is always visible, so this keeps updating
// at the sampling rate even while no window is open.
import AppKit
import SwiftUI
import FlightDeckCore

/// What the Dock tile draws; the raw value is stored in the "dockMode" user default and shown in menus.
enum DockMode: String, CaseIterable, Identifiable {
    case cpuHistory = "CPU History", cores = "CPU Cores", gauges = "System Gauges", appIcon = "App Icon"
    var id: String { rawValue }
}

/// Live Dock tile. Always reflects the live system (even while replaying a trace).
/// Created lazily on first use; its initializer installs the tile view, so headless runs (which never touch it) leave
/// the Dock alone.
@MainActor
final class DockIconController {
    static let shared = DockIconController()
    private let view = DockTileView()
    // Last 40 samples of total and system CPU % (independent of the graph history length); nil = gap.
    private var cpu: [Double?] = Array(repeating: nil, count: 40)
    private var sys: [Double?] = Array(repeating: nil, count: 40)

    /// Read from user defaults each time so the Dock menu, the Monitor menu and Settings all stay in sync.
    var mode: DockMode {
        get { DockMode(rawValue: UserDefaults.standard.string(forKey: "dockMode") ?? "") ?? .cpuHistory }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "dockMode"); refresh() }
    }

    private init() {
        view.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
        NSApp.dockTile.contentView = view
    }

    /// Main actor, once per live sample. `caution` is the worst live finding's severity raw value (0 when none).
    private var lastLamps: (Bool, Int)?

    func ingest(_ s: Snapshot, recording: Bool, caution: Int = 0) {
        // The static App Icon mode shows no live data: only redraw when the recording or caution lamp changes.
        if mode == .appIcon {
            defer { lastLamps = (recording, caution) }
            if let l = lastLamps, l == (recording, caution) { return }
        }
        cpu.removeFirst(); cpu.append(s.cpu.total.value)
        sys.removeFirst(); sys.append(s.cpu.system.value)
        var d = DockData()
        d.cpu = cpu; d.sys = sys
        // Per-core totals are % of that core (0–100), kept with their P/E kind for colouring.
        d.cores = s.cpu.cores.map { ($0.total, $0.kind) }
        // Memory gauge = used / total; nil (unavailable, drawn as "—") rather than 0 if total is unknown.
        d.mem = s.memory.total > 0 ? Double(s.memory.used) / Double(s.memory.total) : nil
        d.temp = s.power.hottest.value
        d.recording = recording
        d.caution = caution
        view.data = d
        refresh()
    }

    /// Called by Engine when sampling resumes after a pause, so the history graph shows a break instead of joining across.
    func gap() { cpu.removeFirst(); cpu.append(nil); sys.removeFirst(); sys.append(nil) }

    /// Re-reads mode and theme, then asks the Dock to redraw. The Dock only redraws on `display()`.
    func refresh() {
        view.mode = mode
        view.palette = Palette.of(ThemeID(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .dark)
        view.needsDisplay = true
        NSApp.dockTile.display()
    }

    /// Right-click Dock menu (via AppDelegate.applicationDockMenu): choose the Dock mode.
    func dockMenu() -> NSMenu {
        let m = NSMenu()
        let header = NSMenuItem(title: "Dock Icon", action: nil, keyEquivalent: ""); header.isEnabled = false
        m.addItem(header)
        for d in DockMode.allCases {
            let it = ClosureMenuItem(d.rawValue) { [weak self] in self?.mode = d }
            it.state = d == mode ? .on : .off
            it.indentationLevel = 1
            m.addItem(it)
        }
        return m
    }
}

/// Everything DockTileView draws, prepared by DockIconController (or with demo values by IconRenderer).
/// Percentages are 0–100; `mem` is a 0…1 fraction; `temp` is °C. nil = unavailable.
struct DockData {
    var cpu: [Double?] = []
    var sys: [Double?] = []
    var cores: [(Double, CoreKind)] = []
    var mem: Double?
    var temp: Double?
    var recording = false
    var caution = 0          // worst finding severity (2 caution, 3 warning)
}
