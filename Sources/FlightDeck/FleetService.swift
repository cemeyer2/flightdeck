// Fleet, sharing side: when "Share this Mac with my other Macs" is on (Settings › Network › Fleet, off by default),
// a FleetListener serves this Mac's vital signs, findings and a 30-minute history to paired Macs and advertises it
// over Bonjour. Each reply is built on demand from the Engine's live state; the only standing work is one history
// point every 30 s (a copy of four numbers from the latest sample). Never runs in demo mode.
import SwiftUI
import SystemConfiguration
import FlightDeckCore

@MainActor
final class FleetService: ObservableObject {
    static let shared = FleetService()
    static let sharingKey = "fleetSharing"
    /// Both roles share one store (and one fleet ID). Memory only in demo mode, so demo pairing can't touch the file.
    let store = FleetStore(dir: Demo.isEnabled ? nil : FleetStore.defaultDirectory)

    private weak var engine: Engine?
    private var server: FleetServer?
    private var listener: FleetListener?
    private var historyTimer: Timer?
    /// One point every `historyStep` seconds, at most 30 minutes.
    nonisolated static let historyStep: TimeInterval = 30, historyCount = 60
    private var history: [FleetPoint] = []

    @Published private(set) var status: String?
    @Published private(set) var pairing = FleetServer.PairingState()
    @Published private(set) var viewers: [FleetPeer] = []

    func configure(engine: Engine) {
        self.engine = engine
        apply()
        FleetModel.shared.startBackground()
    }

    var sharing: Bool { UserDefaults.standard.bool(forKey: Self.sharingKey) && !Demo.isEnabled }

    /// Starts or stops sharing to match the setting.
    func apply() {
        listener?.stop(); listener = nil; server = nil
        historyTimer?.invalidate(); historyTimer = nil
        viewers = store.snapshot.viewers
        guard sharing, engine != nil else { status = nil; pairing = .init(); history = []; return }
        let name = Self.computerName
        let s = FleetServer(store: store, hostName: name) { await FleetService.shared.currentStatus() }
        s.onPaired = { _ in Task { @MainActor in FleetService.shared.refresh() } }
        let l = FleetListener(server: s, advertise: true, serviceName: name)
        server = s; listener = l
        status = "Starting…"
        l.start { err in
            Task { @MainActor in
                guard FleetService.shared.listener === l else { return }
                FleetService.shared.status = err.map { "Couldn't start sharing: \($0)" } ?? "Sharing on the local network as “\(name)”"
            }
        }
        seedHistory()
        historyTimer = Timer.scheduledTimer(withTimeInterval: Self.historyStep, repeats: true) { _ in
            Task { @MainActor in FleetService.shared.addHistoryPoint() }
        }
    }

    // MARK: Pairing (Settings)

    func openPairing() { server?.openPairing(); refresh() }
    func closePairing() { server?.closePairing(); refresh() }
    func removeViewer(_ id: String) { store.removeViewer(id); refresh() }
    /// Re-reads the pairing state (the code changes after a failed attempt) and the viewer list. Settings calls this
    /// every second while the code is shown.
    func refresh() {
        pairing = server?.pairingState() ?? .init()
        viewers = store.snapshot.viewers
    }

    // MARK: Status

    /// The computer name from System Settings › Sharing (SCDynamicStore: unlike Host.current() it never does DNS).
    nonisolated static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    nonisolated static func identity(id: String, hasBattery: Bool) -> FleetIdentity {
        let model = Sysctl.string("hw.model") ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return FleetIdentity(id: id, name: computerName, model: model, kind: FleetIdentity.kind(model: model, hasBattery: hasBattery),
                             macOS: "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : ""), appVersion: MCPEndpoint.version)
    }

    /// What a paired viewer gets: the latest live sample (not a replayed recording), live findings and recent incidents.
    func currentStatus() -> FleetStatus? {
        guard let engine else { return nil }
        let snap = engine.liveSnapshot
        let uptime = Sysctl.timeval("kern.boottime").map { Date().timeIntervalSince($0) }
        let findings = engine.liveFindings + engine.reportFindings + engine.sleepFindings
        return FleetStatus.build(identity: Self.identity(id: store.instanceID, hasBattery: snap?.power.battery != nil), snapshot: snap,
                                 findings: findings, incidents: Array(engine.incidents.suffix(50)), history: history,
                                 uptime: uptime, redaction: .current)
    }

    private func addHistoryPoint() {
        guard let s = engine?.liveSnapshot else { return }
        history.append(FleetPoint(s))
        if history.count > Self.historyCount { history.removeFirst(history.count - Self.historyCount) }
    }

    /// Fills the first 30 minutes from the black box's coarse tier (once, off the main thread), so sparklines aren't
    /// empty right after sharing is turned on.
    private func seedHistory() {
        guard let blackBox = engine?.blackBox, history.isEmpty else { return }
        Task.detached(priority: .utility) {
            let frames = blackBox.trace(.coarse, from: Date().addingTimeInterval(-1800))?.frames ?? []
            var points: [FleetPoint] = [], last = Date.distantPast
            for f in frames where f.time.timeIntervalSince(last) >= FleetService.historyStep { points.append(FleetPoint(f)); last = f.time }
            let seeded = points
            await MainActor.run {
                let s = FleetService.shared
                guard s.history.allSatisfy({ p in seeded.last.map { p.t > $0.t } ?? true }) else { return }
                s.history = Array((seeded + s.history).suffix(FleetService.historyCount))
            }
        }
    }
}
