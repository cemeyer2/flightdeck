// Peripherals in the app: the one live link watch (IOKit plug/unplug notifications) and the accessory battery recorder
// (an IORegistry read every 20 minutes), started by the Engine; never in demo mode or a headless engine, so demo mode
// records nothing and raises no finding about this Mac's devices.
import Foundation
import FlightDeckCore

enum PeripheralsService {
    /// nil in demo mode (`-demo YES`).
    static let recorder: AccessoryRecorder? = UserDefaults.standard.bool(forKey: "demo")
        ? nil : AccessoryRecorder(store: AccessoryStore(dir: AccessoryStore.defaultDirectory))
    /// Posted (on the main queue) after the watch re-reads links because something was plugged in or out.
    static let linksChanged = Notification.Name("FlightDeckPeripheralLinksChanged")

    static func start() {
        guard let recorder else { return }
        PeripheralWatch.shared.onChange = { _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: linksChanged, object: nil) }
        }
        PeripheralWatch.shared.start()
        recorder.start()
    }

    /// Slow-drive findings (once per plug-in) and low accessory batteries (once per discharge). Engine sampling queue.
    static func findings(now: Date) -> [Finding] {
        guard let recorder else { return [] }
        return PeripheralWatch.shared.findings(now: now) + recorder.findings(now: now)
    }

    /// What the page loads: the live report (recording this load's battery levels), or the invented demo one.
    static func load() -> PeripheralsReport {
        recorder.map { Peripherals.collect(recorder: $0) } ?? DemoPeripherals.report()
    }
}
