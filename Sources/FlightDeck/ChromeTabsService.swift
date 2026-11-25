// Chrome tabs, app side: while "Chrome tabs" is on (Settings › Integrations, off by default) and not in demo mode, the
// app listens on the private socket for native hosts launched by the FlightDeck Tabs extension. Tables go into `store`,
// which the Engine resolves against each sample on its sampler queue. Turning it off closes the socket and forgets
// every tab. Tab data is held in memory only.
import SwiftUI
import FlightDeckCore

@MainActor
final class ChromeTabsService: ObservableObject {
    static let shared = ChromeTabsService()
    static let enabledKey = "chromeTabsEnabled"
    /// The one store, shared with the Engine (which reads it on its sampler queue). Created on first use.
    nonisolated static let sharedStore = ChromeTabStore()
    nonisolated var store: ChromeTabStore { Self.sharedStore }

    @Published var enabled = UserDefaults.standard.bool(forKey: ChromeTabsService.enabledKey) {
        didSet { if enabled != oldValue { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); setEnabled(enabled) } }
    }
    /// Why the listener couldn't start (shown in Settings), nil when it's fine or off.
    @Published private(set) var listenerError: String?
    /// Bumped whenever a host connects, says hello, sends a table or goes away, so Settings refreshes its status.
    @Published private(set) var revision = 0

    private var listener: ChromeTabsListener?

    /// At launch: starts listening if the feature is on. Never in demo mode.
    func startIfEnabled() {
        guard enabled, !Demo.isEnabled else { return }
        startListener()
    }

    func setEnabled(_ on: Bool) {
        if on && !Demo.isEnabled {
            startListener()
        } else {
            listener?.stop(); listener = nil
            store.removeAll()
            listenerError = nil
            revision += 1
        }
    }

    private func startListener() {
        guard listener == nil else { return }
        let requirement = ChromePeerAuth.ownRequirement()
        let l = ChromeTabsListener(socket: ChromeTabsSocket.defaultSocketURL(), store: store) { fd in
            ChromePeerAuth.authorize(fd: fd, requirement: requirement)
        }
        l.onChange = { Task { @MainActor in ChromeTabsService.shared.revision += 1 } }   // set before start: read from other queues
        do {
            try l.start()
            listener = l; listenerError = nil
        } catch let e as ChromeTabsSocket.SetupError {
            listenerError = Self.describe(e)
        } catch {
            listenerError = "Couldn't open the Chrome tabs socket: \(error.localizedDescription)"
        }
        revision += 1
    }

    static func describe(_ e: ChromeTabsSocket.SetupError) -> String {
        switch e {
        case .notDirectory, .symlink, .wrongOwner, .wrongMode:
            return "The Chrome tabs folder in Application Support isn't a private folder of yours; remove “Flightdeck/ChromeTabs” and turn this on again"
        case .staleNotSocket, .staleWrongOwner:
            return "Something other than FlightDeck's socket is in the Chrome tabs folder; remove “Flightdeck/ChromeTabs” and turn this on again"
        case .pathTooLong:
            return "The Chrome tabs socket path is too long"
        }
    }
}

extension Engine {
    /// The in-app line under a Chrome CPU finding naming the busiest tabs ("Mostly: youtube.com — Lofi (120%)"), from the
    /// live attribution only (nil while replaying). The finding itself, and so notifications and the Flight Log, keep
    /// the app-level wording.
    func chromeTabsLine(for f: Finding) -> String? {
        guard mode == .live, f.id.hasPrefix("cpu:"), !chromeTabs.isEmpty else { return nil }
        return ChromeTabText.mostlyLine(pids: f.pids ?? [], processes: liveSnapshot?.processes ?? [], attribution: chromeTabs)
    }
}
