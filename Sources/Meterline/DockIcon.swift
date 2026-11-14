import AppKit
import SwiftUI
import MeterCore

enum DockMode: String, CaseIterable, Identifiable {
    case cpuHistory = "CPU History", cores = "CPU Cores", gauges = "System Gauges", appIcon = "App Icon"
    var id: String { rawValue }
}

/// Live Dock tile. Always reflects the live system (even while replaying a trace).
@MainActor
final class DockIconController {
    static let shared = DockIconController()
    private let view = DockTileView()
    private var cpu: [Double?] = Array(repeating: nil, count: 40)
    private var sys: [Double?] = Array(repeating: nil, count: 40)

    var mode: DockMode {
        get { DockMode(rawValue: UserDefaults.standard.string(forKey: "dockMode") ?? "") ?? .cpuHistory }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "dockMode"); refresh() }
    }

    private init() {
        view.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
        NSApp.dockTile.contentView = view
    }

    func ingest(_ s: Snapshot, recording: Bool) {
        cpu.removeFirst(); cpu.append(s.cpu.total.value)
        sys.removeFirst(); sys.append(s.cpu.system.value)
        var d = DockData()
        d.cpu = cpu; d.sys = sys
        d.cores = s.cpu.cores.map { ($0.total, $0.kind) }
        d.mem = s.memory.total > 0 ? Double(s.memory.used) / Double(s.memory.total) : nil
        d.pressure = s.memory.pressure.value.map { $0 / 100 }
        d.temp = s.power.hottest.value
        d.recording = recording
        view.data = d
        refresh()
    }

    func gap() { cpu.removeFirst(); cpu.append(nil); sys.removeFirst(); sys.append(nil) }

    func refresh() {
        view.mode = mode
        view.palette = Palette.of(ThemeID(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .dark)
        view.needsDisplay = true
        NSApp.dockTile.display()
    }

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

struct DockData {
    var cpu: [Double?] = []
    var sys: [Double?] = []
    var cores: [(Double, CoreKind)] = []
    var mem: Double?
    var pressure: Double?
    var temp: Double?
    var recording = false
}
