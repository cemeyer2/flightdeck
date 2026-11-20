import Foundation
// Output of the read-only `fleet` MCP tool: the other Macs this one is paired with (Fleet page), each asked for its
// status now over the paired, signed and encrypted Fleet protocol (FleetClient), in parallel with a short timeout.
// It returns exactly what the Fleet page shows and nothing more: the sharing Mac already redacts its findings
// (FleetRedaction). With nothing paired it says how to pair; it never pairs, unpairs or changes anything.

/// One paired Mac as the tool saw it: its status, or why it couldn't be reached.
public struct FleetHostResult: Sendable {
    public var peer: FleetPeer
    public var status: FleetStatus?
    public var error: String?
    public init(peer: FleetPeer, status: FleetStatus?, error: String?) { self.peer = peer; self.status = status; self.error = error }
}

extension MCPTools {
    func fleet() async throws -> JSON {
        let results = await fleetRunner()
        return Self.fleetJSON(results, now: now())
    }

    /// Asks every paired Mac for its status at once (Bonjour name lookup, then the signed request), 6 s each.
    static func queryFleet(store: FleetStore) async -> [FleetHostResult] {
        let state = store.snapshot
        return await withTaskGroup(of: FleetHostResult.self) { group in
            for peer in state.hosts {
                group.addTask {
                    var client = FleetClient(serviceName: peer.serviceName ?? peer.name)
                    client.timeout = 6
                    do { return FleetHostResult(peer: peer, status: try await client.status(host: peer, viewerID: state.instanceID), error: nil) }
                    catch { return FleetHostResult(peer: peer, status: nil, error: "\(error)") }
                }
            }
            var out: [FleetHostResult] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.peer.name.localizedCaseInsensitiveCompare($1.peer.name) == .orderedAscending }
        }
    }

    static func fleetValue(_ v: FleetValue, _ format: (Double) -> JSON) -> JSON {
        v.value.map(format) ?? F.unavailable(v.reason ?? "not reported")
    }

    static func fleetFindingJSON(_ f: FleetFinding, now: Date) -> JSON {
        let severity = f.severity >= 2 ? "warning" : f.severity == 1 ? "caution" : "info"
        return .object(dropping: [
            ("severity", .str(severity)), ("kind", .str(f.kind)), ("title", .str(f.title)), ("detail", f.detail.map(JSON.str)),
            ("since", .str(ISO8601DateFormatter().string(from: f.since))),
            ("ended", f.end.map { .str(ISO8601DateFormatter().string(from: $0)) }),
        ])
    }

    static func fleetVitalsJSON(_ v: FleetVitals) -> JSON {
        let thermal = ["nominal", "fair", "serious", "critical"]
        let battery: JSON = v.battery.map { b in
            .object([("percent", .int(Int(b.percent.rounded()))), ("charging", .bool(b.charging)), ("on_power", .bool(b.onPower))])
        } ?? F.unavailable(v.batteryReason ?? "no battery")
        return .object(dropping: [
            ("cpu_pct", fleetValue(v.cpu) { F.r1($0) }),
            ("memory_pressure_pct", fleetValue(v.memoryPressure) { F.r1($0) }),
            ("memory_used_gb", fleetValue(v.memoryUsed) { F.r1($0 / 1_073_741_824) }),
            ("memory_total_gb", fleetValue(v.memoryTotal) { F.r1($0 / 1_073_741_824) }),
            ("hottest_c", fleetValue(v.hottest) { F.r1($0) }),
            ("startup_disk_free_gb", fleetValue(v.diskFree) { F.r1($0 / 1e9) }),
            ("startup_disk_total_gb", fleetValue(v.diskTotal) { F.r1($0 / 1e9) }),
            ("battery", battery),
            ("uptime_hours", fleetValue(v.uptime) { F.r1($0 / 3600) }),
            ("thermal_state", .str(v.thermalState >= 0 && v.thermalState < thermal.count ? thermal[v.thermalState] : "unknown")),
            ("sampled", .str(ISO8601DateFormatter().string(from: v.sampledAt))),
        ])
    }

    static func fleetHostJSON(_ r: FleetHostResult, now: Date) -> JSON {
        let iso = ISO8601DateFormatter()
        guard let s = r.status else {
            return .object(dropping: [
                ("name", .str(r.peer.name)), ("online", .bool(false)),
                ("last_seen", r.peer.lastSeen.map { .str(iso.string(from: $0)) }),
                ("why", .str("No answer: the Mac may be asleep, off, on another network, or no longer sharing (\(r.error ?? "unknown error")).")),
            ])
        }
        let worst = s.worst
        return .object(dropping: [
            ("name", .str(s.identity.name)), ("online", .bool(true)),
            ("model", .str(s.identity.model)), ("macos", .str(s.identity.macOS)), ("flightdeck", .str(s.identity.appVersion)),
            ("vitals", s.vitals.map(fleetVitalsJSON) ?? F.unavailable(s.vitalsReason ?? "no sample yet")),
            ("worst", worst.map { .str($0.title) } ?? .str("no problems")),
            ("findings", .array(s.findings.map { fleetFindingJSON($0, now: now) })),
            ("recent_incidents", s.incidents.isEmpty ? nil : .array(s.incidents.prefix(10).map { fleetFindingJSON($0, now: now) })),
        ])
    }

    static func fleetJSON(_ results: [FleetHostResult], now: Date) -> JSON {
        guard !results.isEmpty else {
            return .object([
                ("paired_macs", .int(0)),
                ("note", .str("No Macs are paired. On the other Mac, turn on FlightDeck Settings › Network › Fleet › Share this Mac and click Pair a Mac; then open the Fleet page here and enter the code.")),
            ])
        }
        let online = results.filter { $0.status != nil }
        let troubled = online.filter { ($0.status?.worst?.severity ?? -1) >= 1 }.map { $0.status!.identity.name }
        return .object(dropping: [
            ("paired_macs", .int(results.count)), ("online", .int(online.count)),
            ("needs_attention", troubled.isEmpty ? nil : .strings(troubled)),
            ("macs", .array(results.map { fleetHostJSON($0, now: now) })),
            ("note", .str("Read-only. Each Mac shares only vital signs and redacted findings; nothing here can change them.")),
        ])
    }
}
