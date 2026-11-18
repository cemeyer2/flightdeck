// State behind the Network view. One shared model, so what was discovered (and first-seen times) survives switching
// to another view and back. Work happens only while the view is visible: a full survey (Bonjour browse, reverse DNS,
// neighbour caches) when it appears or on Refresh, and a light re-read of the neighbour caches every 10 s. The active
// scan and traceroute run only from their buttons. In demo mode nothing live is ever called.
import SwiftUI
import FlightDeckCore

@MainActor
final class NetworkMapModel: ObservableObject {
    static let shared = NetworkMapModel()

    @Published var survey: NetworkSurvey?
    /// What is running right now ("Browsing Bonjour…"); nil when idle.
    @Published var busy: String?
    /// Outcome of the last active scan or traceroute, in plain English.
    @Published var status: String?
    /// Selected device id (map or list).
    @Published var selected: String?
    @Published var hops: [TraceHop] = []

    /// True for a model fed fixed data (demo mode, off-screen renders): no live collector is ever called.
    let fixed: Bool
    private var services: [BonjourService] = []
    private var names: [String: String] = [:]
    private var seen: [String: (first: Date, last: Date)] = [:]
    private var lastFull: Date?
    /// Hosts from the last UPnP search (full refreshes only).
    private var upnpHosts: [UPnPHostInfo] = []
    private var timer: Timer?

    init() { fixed = Demo.isEnabled; if fixed { load(Demo.networkSurvey()) } }
    /// A model showing a prepared survey (UIBench).
    init(survey: NetworkSurvey) { fixed = true; load(survey) }

    private func load(_ s: NetworkSurvey) { survey = s; hops = s.topology.hops }

    /// View appeared: a full survey unless one ran in the last minute, then quick re-reads every 10 s.
    func appear() {
        guard !fixed else { return }
        if lastFull.map({ Date().timeIntervalSince($0) > 60 }) ?? true { refresh(full: true) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(full: false) }
        }
    }

    func disappear() { timer?.invalidate(); timer = nil }

    /// `full` browses Bonjour (~6 s) before reading everything else; otherwise the last Bonjour results are reused.
    /// Skipped while another operation runs, so the 10 s timer never stacks work.
    func refresh(full: Bool) {
        guard !fixed, busy == nil else { return }
        // A quick re-read sets an empty label: work is in progress (so nothing overlaps) but nothing is announced.
        busy = full ? "Browsing Bonjour and reading the ARP table…" : ""
        let known = names, seenNow = seen, hopsNow = hops, cached = services
        let upnpCached = upnpHosts
        Task.detached {
            // A full refresh also runs a UPnP search (~3 s) alongside the Bonjour browse, for names and models.
            async let upnp: [UPnPHostInfo] = full ? UPnPScan.run().hosts : upnpCached
            let svc = full ? BonjourBrowser.browse() : cached
            let (s, n) = NetworkDiscovery.survey(services: svc, knownNames: known, seen: seenNow, hops: hopsNow)
            let hosts = await upnp
            await MainActor.run { self.upnpHosts = hosts; self.finish(s, names: n, services: svc, full: full) }
        }
    }

    private func finish(_ raw: NetworkSurvey, names n: [String: String], services svc: [BonjourService], full: Bool) {
        names = n; services = svc
        // UPnP names/models by IP, and a configured UniFi console's names and real attachments (AP / switch port) by MAC.
        let s = NetworkEnrichment.apply(raw, upnp: upnpHosts, unifi: UniFiModel.shared.snapshot)
        for d in s.devices { seen[d.id] = (seen[d.id]?.first ?? d.firstSeen, d.lastSeen) }
        // Re-apply first-seen from the session history (the survey only knew what was passed in when it started).
        var s2 = s
        for i in s2.devices.indices { if let f = seen[s2.devices[i].id]?.first { s2.devices[i].firstSeen = f } }
        survey = s2
        if full { lastFull = Date() }
        busy = nil
    }

    /// First-seen time for a device this session, kept even after it leaves the ARP table.
    func firstSeen(_ id: String) -> Date? { seen[id]?.first }

    /// The interface address the active scan would cover, and how many addresses that is.
    var scanTarget: (net: IPv4Net, count: Int)? {
        guard let b = survey?.topology.primary, b.interface.kind != .vpn,
              let net = b.interface.ipv4.first(where: { !(IPv4.parse($0.address).map(IPv4.isLinkLocal) ?? true) }) else { return nil }
        let n = ActiveScan.targets(for: net).count
        return n > 0 ? (net, n) : nil
    }

    /// Pings every address of the primary subnet once (see ActiveScan), then re-reads the neighbour caches.
    func activeScan() {
        guard !fixed, busy == nil, let t = scanTarget else { return }
        busy = "Pinging \(t.count) addresses on \(t.net.cidr)…"
        status = nil
        let targets = ActiveScan.targets(for: t.net)
        Task.detached {
            let r = ActiveScan.run(targets)
            await MainActor.run {
                self.busy = nil
                let before = self.survey?.devices.count ?? 0
                self.status = r.error.map { "Active scan: sent \(r.sent) of \(targets.count) pings; sending failed: \($0)." }
                    ?? "Active scan: sent \(r.sent) pings."
                self.refreshAfterScan(before: before)
            }
        }
    }

    private func refreshAfterScan(before: Int) {
        refresh(full: false)
        // Report the difference once the re-read lands.
        Task { @MainActor in
            while busy != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
            let after = survey?.devices.count ?? 0
            status = (status ?? "") + " \(max(0, after - before)) new device\(after - before == 1 ? "" : "s") in the ARP table."
        }
    }

    /// Traces the route to 1.1.1.1 (the same host as the latency probe's default) and adds the hops to the map.
    func traceroute() {
        guard !fixed, busy == nil else { return }
        busy = "Tracing the route to 1.1.1.1…"
        status = nil
        Task.detached {
            let h = Traceroute.run(to: "1.1.1.1")
            await MainActor.run {
                self.busy = nil
                guard let h else { self.status = "traceroute couldn't be run."; return }
                self.hops = h
                self.status = "Traceroute: \(h.count) hop\(h.count == 1 ? "" : "s") to 1.1.1.1, \(h.filter { $0.ip == nil }.count) didn't answer."
                if let s = self.survey {
                    var s2 = s
                    s2.topology = NetTopology.build(interfaces: s.interfaces, devices: s.devices, route: s.route, wifi: s.accessPoint, hops: h)
                    self.survey = s2
                }
            }
        }
    }
}
