// Fleet, viewing side: the Macs this one has paired with, and any others advertising FlightDeck nearby. While the Fleet
// page is open it browses Bonjour and polls each paired Mac every 10 s; otherwise it polls every 5 minutes (only if
// any are paired) so the menu bar and alerts can say "Studio: memory pressure critical". Nothing runs in demo mode,
// where the page shows invented Macs.
import SwiftUI
import FlightDeckCore

/// One paired Mac as the page shows it.
struct FleetHostState: Identifiable {
    var peer: FleetPeer
    var status: FleetStatus?
    /// nil until the first poll finishes.
    var online: Bool?
    var lastError: String?
    var id: String { peer.id }
    var name: String { status?.identity.name ?? peer.name }
}

@MainActor
final class FleetModel: ObservableObject {
    static let shared = FleetModel()
    static let visibleInterval: TimeInterval = 10, backgroundInterval: TimeInterval = 300

    @Published private(set) var hosts: [FleetHostState] = []
    /// Macs advertising FlightDeck that aren't paired (and aren't this one).
    @Published private(set) var unpaired: [FleetAdvert] = []
    @Published var selected: String?
    @Published private(set) var pairingWith: String?
    @Published var pairError: String?
    /// Demo and render models never touch the network.
    let fixed: Bool
    private let store: FleetStore
    private var browser: FleetBrowser?
    private var adverts: [FleetAdvert] = []
    private var visible = 0
    private var loop: Task<Void, Never>?

    init() {
        store = FleetService.shared.store; fixed = Demo.isEnabled
        if Demo.isEnabled { (hosts, unpaired) = DemoFleet.model() } else { hosts = store.snapshot.hosts.map { FleetHostState(peer: $0) } }
    }
    /// A model with invented or prebuilt contents (demo, UIBench).
    init(preview hosts: [FleetHostState], unpaired: [FleetAdvert], selected: String? = nil) {
        store = FleetStore(dir: nil); fixed = true
        self.hosts = hosts; self.unpaired = unpaired; self.selected = selected
    }

    // MARK: Lifecycle

    func appeared() {
        guard !fixed else { return }
        visible += 1
        if browser == nil {
            let b = FleetBrowser { found in Task { @MainActor in FleetModel.shared.found(found) } }
            browser = b; b.start()
        }
        restartLoop()
    }

    func disappeared() {
        guard !fixed else { return }
        visible = max(0, visible - 1)
        if visible == 0 { browser?.stop(); browser = nil; restartLoop() }
    }

    /// At launch: the slow "is it OK" poll, if anything is paired.
    func startBackground() { if !fixed { restartLoop() } }

    private func restartLoop() {
        loop?.cancel()
        guard !hosts.isEmpty || visible > 0 else { loop = nil; FleetWatch.shared.set([]); return }
        let interval = visible > 0 ? Self.visibleInterval : Self.backgroundInterval
        loop = Task { [weak self] in
            // In the background, wait one interval first: nothing needs a fleet answer in the first seconds of launch.
            if interval == Self.backgroundInterval { try? await Task.sleep(for: .seconds(60)) }
            while !Task.isCancelled {
                await self?.pollAll()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func found(_ list: [FleetAdvert]) {
        adverts = list
        let me = store.instanceID
        let paired = Set(hosts.map(\.id))
        // Remember the instance name each paired Mac currently advertises (Bonjour may rename on a conflict).
        for a in list { if let id = a.id, paired.contains(id), let i = hosts.firstIndex(where: { $0.id == id }), hosts[i].peer.serviceName != a.name {
            hosts[i].peer.serviceName = a.name
            let peer = hosts[i].peer
            store.update { s in if let j = s.hosts.firstIndex(where: { $0.id == peer.id }) { s.hosts[j].serviceName = peer.serviceName } }
        } }
        unpaired = list.filter { a in a.id != me && !(a.id.map(paired.contains) ?? false) }
    }

    // MARK: Polling

    func pollAll() async {
        let viewerID = store.instanceID
        await withTaskGroup(of: (String, Result<FleetStatus, Error>).self) { group in
            for h in hosts {
                let peer = h.peer
                group.addTask { (peer.id, await Self.fetch(peer, viewerID: viewerID)) }
            }
            for await (id, r) in group { apply(id, r) }
        }
        let paired: [(name: String, id: String, status: FleetStatus)] = hosts.compactMap { h in
            guard h.online == true, let s = h.status else { return nil }
            return (h.name, h.id, s)
        }
        FleetWatch.shared.set(FleetWatch.findings(for: paired))
    }

    nonisolated static func fetch(_ peer: FleetPeer, viewerID: String) async -> Result<FleetStatus, Error> {
        do { return .success(try await FleetClient(serviceName: peer.serviceName ?? peer.name).status(host: peer, viewerID: viewerID)) }
        catch { return .failure(error) }
    }

    private func apply(_ id: String, _ r: Result<FleetStatus, Error>) {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        switch r {
        case .success(let s):
            hosts[i].status = s; hosts[i].online = true; hosts[i].lastError = nil
            let now = Date(), previous = hosts[i].peer.lastSeen
            hosts[i].peer.lastSeen = now
            // Saved at most every 10 minutes (it only feeds "last seen" after a relaunch).
            if now.timeIntervalSince(previous ?? .distantPast) > 600 || hosts[i].peer.model != s.identity.model {
                hosts[i].peer.model = s.identity.model; hosts[i].peer.kind = s.identity.kind; hosts[i].peer.name = s.identity.name
                let peer = hosts[i].peer
                store.update { st in if let j = st.hosts.firstIndex(where: { $0.id == id }) { st.hosts[j] = peer } }
            }
        case .failure(let e):
            hosts[i].online = false
            hosts[i].lastError = (e as? FleetError)?.message ?? "Not reachable"
        }
    }

    // MARK: Pairing

    func pair(_ advert: FleetAdvert, code: String) async -> Bool {
        guard !fixed else { return false }
        pairingWith = advert.name; pairError = nil
        defer { pairingWith = nil }
        do {
            var peer = try await FleetClient(serviceName: advert.name).pair(code: code, viewerID: store.instanceID, viewerName: FleetService.computerName)
            peer.serviceName = advert.name
            store.addHost(peer)
            hosts.removeAll { $0.id == peer.id }
            hosts.append(FleetHostState(peer: peer))
            found(adverts)
            restartLoop()
            return true
        } catch {
            pairError = (error as? FleetError)?.message ?? "Couldn't reach \(advert.name): \(error.localizedDescription)"
            return false
        }
    }

    func forget(_ id: String) {
        guard !fixed else { return }
        store.removeHost(id)
        hosts.removeAll { $0.id == id }
        if selected == id { selected = nil }
        found(adverts)
        restartLoop()
    }
}
