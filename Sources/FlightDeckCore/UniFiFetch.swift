// The read flows: one call to `fetch()` assembles a UniFiSnapshot.
//  • API key: the official Integration API for sites, devices (list, detail and latest statistics) and clients, then the
//    classic `stat/device`, `stat/sta` and `stat/health` with the same key where the console accepts it (UniFi Network
//    9+ does), because only those carry switch ports, signal, traffic and WAN health. Classic data fills gaps only.
//  • Username/password: classic login, then the classic endpoints.
// Whatever a console doesn't provide is listed in `notes`.
import Foundation

public extension UniFiAPIClient {
    /// One full read of the configured site.
    func fetch() async throws -> UniFiSnapshot {
        switch credentials {
        case .apiKey: return try await fetchIntegration()
        case .password: return try await fetchClassic(source: .classic)
        }
    }

    /// For Settings › Test connection: a one-line summary of what the console returned.
    func testConnection() async throws -> String {
        let s = try await fetch()
        let site = s.site?.description ?? s.site?.name ?? config.site
        let api = s.source == .classic ? "classic API" : s.source == .integration ? "Integration API" : "Integration + classic API"
        return "Connected (\(api)): site \"\(site)\", \(s.devices.count) devices, \(s.clients.count) clients."
    }
}

extension UniFiAPIClient {
    /// Finds the integration API's path prefix (UniFi OS, then a self-hosted Network application) and its sites.
    func integrationSites() async throws -> [UniFiSite] {
        var lastError: Error = UniFiError.notFound("integration/v1/sites")
        for p in prefix.map({ [$0] }) ?? ["/proxy/network", ""] {
            do {
                let data = try await get(p + "/integration/v1/sites?limit=200")
                guard let sites = UniFiIntegration.sites(data) else { throw UniFiError.badResponse("integration/v1/sites") }
                prefix = p
                return sites
            } catch UniFiError.notFound(let x) { lastError = UniFiError.notFound(x) }
        }
        throw lastError
    }

    /// Picks the configured site by internal name, ID or display name; with one site and the default name, that one.
    static func pick(_ sites: [UniFiSite], _ wanted: String) throws -> UniFiSite {
        let w = wanted.trimmingCharacters(in: .whitespaces).lowercased()
        if let s = sites.first(where: { $0.name?.lowercased() == w || $0.id.lowercased() == w || $0.description?.lowercased() == w }) { return s }
        if sites.count == 1, w.isEmpty || w == "default" { return sites[0] }
        throw UniFiError.siteNotFound(wanted, available: sites.map { $0.name ?? $0.description ?? $0.id })
    }

    /// Reads every page of an integration list endpoint (at most 2,000 records, which is plenty for one site).
    func pages(_ path: String) async throws -> [Data] {
        var out: [Data] = [], offset = 0
        while offset < 2000 {
            let data = try await get(path + "?offset=\(offset)&limit=200")
            out.append(data)
            let o = UniFiJSON.object(data)
            let count = o?.int("count") ?? UniFiJSON.records(data)?.count ?? 0
            let total = o?.int("totalCount") ?? count
            offset += count
            if count == 0 || offset >= total { break }
        }
        return out
    }

    func fetchIntegration() async throws -> UniFiSnapshot {
        let sites = try await integrationSites()
        let site = try Self.pick(sites, config.site)
        let root = (prefix ?? "") + "/integration/v1/sites/\(site.id)"
        var devices = try await pages(root + "/devices").flatMap { UniFiIntegration.devices($0) ?? [] }
        var clients = try await pages(root + "/clients").flatMap { UniFiIntegration.clients($0) ?? [] }
        // Firmware, uplink, ports and radios are only in each device's detail, live load in its statistics. These are
        // small requests, made a few at a time; a device whose detail fails keeps its list entry.
        var uplinkIDs: [String: String] = [:]
        let details = await withTaskGroup(of: (Int, UniFiDevice?, String?, Data?).self) { g in
            for (i, d) in devices.prefix(100).enumerated() {
                guard let id = d.apiID else { continue }
                g.addTask {
                    let detail = try? await self.get(root + "/devices/\(id)")
                    let stats = try? await self.get(root + "/devices/\(id)/statistics/latest")
                    let parsed = detail.flatMap(UniFiIntegration.deviceDetail)
                    return (i, parsed?.device, parsed?.uplinkDeviceID, stats)
                }
            }
            var out: [(Int, UniFiDevice?, String?, Data?)] = []
            for await r in g { out.append(r) }
            return out
        }
        for (i, detail, uplink, stats) in details {
            if let detail { devices[i] = UniFiMerge.devices([detail], [devices[i]])[0] }
            if let uplink, let id = devices[i].apiID { uplinkIDs[id] = uplink }
            if let stats { UniFiIntegration.applyStatistics(stats, to: &devices[i]) }
        }
        UniFiIntegration.resolve(devices: &devices, uplinkIDs: uplinkIDs, clients: &clients)

        var snap = UniFiSnapshot(time: Date(), source: .integration)
        snap.sites = sites; snap.site = site; snap.devices = devices; snap.clients = clients
        // Enrich with the classic API using the same key, if this console allows it.
        if let name = site.name, let classic = try? await fetchClassic(source: .classic, siteName: name, sites: sites) {
            snap.source = .integrationAndClassic
            snap.devices = UniFiMerge.devices(devices, classic.devices)
            snap.clients = UniFiMerge.clients(clients, classic.clients)
            snap.health = classic.health
            snap.notes = classic.notes
        } else {
            snap.notes = ["This console's Integration API doesn't provide switch ports for clients, Wi-Fi signal, per-client traffic or WAN health, and its classic API didn't accept the API key. Use a local account (username/password) to see them."]
        }
        return snap
    }

    /// The classic endpoints for one site. A missing `stat/health` (rare) leaves health empty with a note; devices and
    /// clients are required.
    func fetchClassic(source: UniFiAPIKind, siteName: String? = nil, sites known: [UniFiSite]? = nil) async throws -> UniFiSnapshot {
        var snap = UniFiSnapshot(time: Date(), source: source)
        let name: String
        if let siteName {
            name = siteName; snap.sites = known ?? []
        } else {
            let data = try await classicGet("/api/self/sites")
            let sites = UniFiClassic.sites(data) ?? []
            snap.sites = sites
            name = sites.isEmpty ? config.site : try Self.pick(sites, config.site).name ?? config.site
        }
        snap.site = snap.sites.first { $0.name == name } ?? UniFiSite(id: name, name: name)
        func checked(_ path: String) async throws -> Data {
            let d = try await classicGet("/api/s/\(name)/" + path)
            if let e = UniFiJSON.classicError(d) { throw e.contains("LoginRequired") ? UniFiError.unauthorized(e) : UniFiError.http(200, "\(path): \(e)") }
            return d
        }
        guard let devices = UniFiClassic.devices(try await checked("stat/device")) else { throw UniFiError.badResponse("stat/device") }
        guard let clients = UniFiClassic.clients(try await checked("stat/sta")) else { throw UniFiError.badResponse("stat/sta") }
        snap.devices = devices; snap.clients = clients
        if let h = (try? await checked("stat/health")).flatMap(UniFiClassic.health) { snap.health = h }
        else { snap.notes.append("WAN health (stat/health) isn't provided by this console.") }
        if snap.health.speedTest == nil { snap.notes.append("No speed test result reported (run one in UniFi Network to see it here).") }
        return snap
    }
}
