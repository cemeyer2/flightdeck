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

    /// The extension inside the app; nil for a `swift build` run, which has no bundle resources.
    var bundledExtension: URL? { Bundle.main.url(forResource: "ChromeExtension", withExtension: nil) }
    var stableCopy: URL {
        ChromeExtensionInstall.stableCopyDir(appSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }
    var hostsDir: URL { ChromeExtensionInstall.nativeHostsDir(home: FileManager.default.homeDirectoryForCurrentUser) }
    var executablePath: String { MCPEndpoint.executablePath }

    /// False when the app runs translocated (opened straight from a download) or from a read-only or removable volume
    /// such as a mounted DMG: a host manifest pointing there would break as soon as the app is moved or ejected.
    var relocatable: Bool {
        let url = Bundle.main.bundleURL
        if Self.isTranslocated(url) { return false }
        let v = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeIsRemovableKey])
        return !(v?.volumeIsReadOnly ?? false) && !(v?.volumeIsRemovable ?? false)
    }

    /// `SecTranslocateIsTranslocatedURL` has no Swift header, so it is looked up at run time; the path test covers the
    /// unlikely case that it's missing.
    static func isTranslocated(_ url: URL) -> Bool {
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecTranslocateIsTranslocatedURL") {   // RTLD_DEFAULT
            var result: DarwinBoolean = false
            if unsafeBitCast(sym, to: Fn.self)(url as CFURL, &result, nil).boolValue { return result.boolValue }
        }
        return url.path.contains("/AppTranslocation/")
    }

    var status: ChromeTabsStatus {
        _ = revision
        let tables = store.tables().values
        return ChromeTabsStatus.compute(enabled: enabled && !Demo.isEnabled, bundledVersion: bundledExtension.flatMap(ChromeExtensionInstall.manifestVersion),
                                        stableVersion: ChromeExtensionInstall.manifestVersion(at: stableCopy),
                                        manifestPresent: ChromeExtensionInstall.readHostManifest(dir: hostsDir) != nil, relocatable: relocatable,
                                        hellos: Array(store.hellos().values), tabCount: tables.reduce(0) { $0 + $1.tabs.count },
                                        listenerError: listenerError)
    }

    /// At launch: heals what was installed (the app may have moved, or been updated with a newer extension) and starts
    /// listening if the feature is on. Never in demo mode.
    func startIfEnabled() {
        guard enabled, !Demo.isEnabled else { return }
        heal()
        startListener()
    }

    func setEnabled(_ on: Bool) {
        if on && !Demo.isEnabled {
            heal()
            startListener()
        } else {
            listener?.stop(); listener = nil
            store.removeAll()
            listenerError = nil
            if !Demo.isEnabled {
                ChromeExtensionInstall.removeHostManifest(dir: hostsDir)
                ChromeExtensionInstall.removeStableCopy(stableCopy)
            }
            revision += 1
        }
    }

    /// Rewrites the host manifest when it doesn't name this app, and refreshes the stable copy when the bundled
    /// extension is newer. Skipped when the app can't stay where it is (see `relocatable`).
    private func heal() {
        guard let bundled = bundledExtension, relocatable else { return }
        if ChromeExtensionInstall.needsRewrite(existing: ChromeExtensionInstall.readHostManifest(dir: hostsDir), executablePath: executablePath) {
            do { try ChromeExtensionInstall.writeHostManifest(dir: hostsDir, executablePath: executablePath) }
            catch { listenerError = "Couldn't write Chrome's native messaging manifest: \(error.localizedDescription)" }
        }
        if let stable = ChromeExtensionInstall.manifestVersion(at: stableCopy), let b = ChromeExtensionInstall.manifestVersion(at: bundled),
           ChromeExtensionInstall.isVersion(b, newerThan: stable) {
            try? ChromeExtensionInstall.installStableCopy(from: bundled, to: stableCopy)
        }
    }

    /// "Set up…": copies the extension to its stable folder, shows it in Finder and opens chrome://extensions, where the
    /// user turns on Developer mode and loads it with "Load unpacked".
    func setUp() {
        guard let bundled = bundledExtension else { return }
        do {
            try ChromeExtensionInstall.installStableCopy(from: bundled, to: stableCopy)
            if ChromeExtensionInstall.needsRewrite(existing: ChromeExtensionInstall.readHostManifest(dir: hostsDir), executablePath: executablePath) {
                try ChromeExtensionInstall.writeHostManifest(dir: hostsDir, executablePath: executablePath)
            }
        } catch {
            listenerError = "Couldn't set up Chrome tabs: \(error.localizedDescription)"; revision += 1; return
        }
        NSWorkspace.shared.activateFileViewerSelecting([stableCopy])
        Self.openExtensionsPage()
        revision += 1
    }

    static func openExtensionsPage() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let page = URL(string: "chrome://extensions") else { return }
        NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
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
