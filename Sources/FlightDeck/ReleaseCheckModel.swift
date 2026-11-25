// Update checks in the app. `ReleaseCheckModel` owns the saved state and the background loop: ~60 s after launch, then
// every hour, it asks the pure `ReleaseCheck.shouldCheck` whether a check is due (on in Settings › About, and 24 h since
// the last one), so an idle wake does no I/O and sleep or clock changes don't cause a catch-up storm. Check Now in
// Settings asks once per click, even with the toggle off. Errors only change the Settings status line. Nothing is read,
// written or requested in demo mode or for an unknown (development) version.
import SwiftUI
import FlightDeckCore

@MainActor
final class ReleaseCheckModel: ObservableObject {
    static let shared = ReleaseCheckModel()
    static let enabledKey = "updateCheck.enabled"

    @Published private(set) var state: ReleaseCheckState
    @Published private(set) var inFlight = false
    /// nil = unknown (no bundle version, or bundle.sh's no-tags fallback): no checks at all.
    let installed: ReleaseVersion?
    /// "FlightDeck 1.6.0 (123)", with "—" for a missing part, as the About panel shows it.
    let versionText: String
    private let demo = Demo.isEnabled
    private let client = ReleaseCheckClient()
    private var started = false

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String, build = info["CFBundleVersion"] as? String
        installed = ReleaseVersion.installed(shortVersion: short, build: build)
        versionText = "FlightDeck \(short ?? "—") (\(build ?? "—"))"
        state = demo ? ReleaseCheckState() : ReleaseCheckState.load(from: .standard)
    }

    var availability: CheckNowAvailability {
        ReleaseCheck.checkNowAvailability(demo: demo, versionKnown: installed != nil, inFlight: inFlight,
                                          now: Date(), retryNotBefore: state.retryNotBefore)
    }
    var statusText: String { ReleaseCheck.statusText(state: state, installed: installed, demo: demo) }
    /// Read at every wake, so the toggle applies without restarting the loop.
    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// Starts the hourly wake once. Called by the Engine.
    func start() {
        guard !started, !demo else { return }
        started = true
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(ReleaseCheck.launchDelay))
            while !Task.isCancelled {
                await ReleaseCheckModel.shared.tick()
                try? await Task.sleep(for: .seconds(ReleaseCheck.wake))
            }
        }
    }

    /// A scheduled check, only if one is due.
    func tick() async {
        guard ReleaseCheck.shouldCheck(now: Date(), lastCheckedAt: state.lastCheckedAt, retryNotBefore: state.retryNotBefore,
                                       enabled: enabled, demo: demo, versionKnown: installed != nil) else { return }
        await run()
    }

    /// One request (plus the single retry after a 304 with nothing cached), whether or not the toggle is on. It writes
    /// the same keys as a scheduled check but doesn't turn the toggle on.
    func checkNow() async {
        guard availability == .available else { return }
        await run()
    }

    /// Settings' toggle: ask for notification permission once (if alerts are on), and check at once if due.
    /// Turning it off clears nothing.
    func enabledChanged(_ on: Bool) {
        guard on, !demo else { return }
        if ReleaseCheck.shouldRequestPermission(toggledOn: on, alertsEnabled: Alerts.shared.enabled, alreadyRequested: state.permissionRequested) {
            Alerts.shared.requestPermission()
            state.permissionRequested = true
            state.save(to: .standard)
        }
        Task { await tick() }
    }

    private func run() async {
        guard !inFlight, !demo, let installed else { return }
        inFlight = true; defer { inFlight = false }
        var (s, outcome) = ReleaseCheck.next(state: state, response: await client.fetchLatest(etag: state.etag), now: Date())
        if outcome == .retryWithoutETag {
            s = ReleaseCheck.next(state: s, response: await client.fetchLatest(etag: nil), now: Date()).state
        }
        // Keep anything changed meanwhile that the response doesn't own (the permission flag).
        s.permissionRequested = state.permissionRequested
        state = s
        state.save(to: .standard)
        guard let notice = ReleaseCheck.notice(latest: state.latest, installed: installed, lastNotified: state.lastNotifiedVersion,
                                               alertsEnabled: Alerts.shared.enabled) else { return }
        let delivered = await Alerts.shared.post(title: notice.title, body: notice.body, url: notice.url, identifier: notice.identifier)
        state.markNotified(notice, delivered: delivered)
        state.save(to: .standard)
    }
}
