import Foundation
// Output of the `temperatures` MCP tool: sensors grouped with session statistics, the hottest sensor per group, fans
// with health, and throttling. With the app, statistics cover the app's session; the standalone CLI has only the
// latest sample, and says so instead of reporting a single reading as min and max.

extension MCPTools {
    func temperatures() async throws -> JSON {
        guard let s = await source.snapshot() else { throw noSample() }
        let session = await source.thermal()
        let catalog = session?.status.catalog ?? SensorCatalog.build(s.power, chip: .current)
        let stats = session?.history.allStats() ?? [:]
        let noStats = F.unavailable(session == nil ? "standalone: no session history" : "no readings yet")

        func sensor(_ c: CatalogSensor) -> JSON {
            let st = stats[c.id]
            return .object(dropping: [
                ("name", .str(c.name)), ("raw", .str(c.raw)), ("source", .str(c.source.rawValue)), ("now_c", F.r1(c.celsius)),
                ("min_c", st.map { F.r1($0.min) } ?? noStats), ("avg_c", st.map { F.r1($0.average) } ?? noStats),
                ("max_c", st.map { F.r1($0.max) } ?? noStats),
                ("calibration_reference", c.reference ? .bool(true) : nil), ("also_reported_as", c.alsoReportedAs.map(JSON.str)),
            ])
        }
        let groups: [(String, JSON)] = catalog.grouped.map { g in (g.group.rawValue, ["title": .str(g.group.title), "sensors": .array(g.sensors.map(sensor))]) }
        let highest: [(String, JSON)] = catalog.families.map { r in
            let st = stats["family:" + r.family.rawValue]
            return (r.family.rawValue, .object(dropping: [("now_c", F.r1(r.max)), ("sensor", .str(r.hottest)),
                                                          ("session_max_c", st.map { F.r1($0.max) } ?? noStats)]))
        }

        // Fans: health comes from the session; standalone shows readings only.
        let fanHealth = Dictionary((session?.status.fans ?? []).map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        let fans: JSON
        switch s.power.fans {
        case nil: fans = F.unavailable("fans couldn't be read")
        case let list? where list.isEmpty: fans = .str("This Mac has no fans.")
        case let list?:
            fans = .array(list.map { f in
                .object(dropping: [("fan", .int(f.index + 1)), ("rpm", .int(Int(f.rpm.rounded()))),
                                   ("target_rpm", f.targetRPM.map { .int(Int($0.rounded())) }), ("min_rpm", f.minRPM.map { .int(Int($0.rounded())) }),
                                   ("max_rpm", f.maxRPM.map { .int(Int($0.rounded())) }), ("percent_of_max", f.fraction.map { F.r1($0 * 100) }),
                                   ("problems", fanHealth[f.index].map { h in .strings(h.issues.map(\.text)) })])
            })
        }

        let t = session?.status.throttle
        let limits = t?.limits
        let throttling: JSON = .object(dropping: [
            ("throttled", t?.throttled.map(JSON.bool) ?? .bool(s.power.thermalState >= 2)),
            ("reasons", t.map { .strings($0.reasons) }),
            ("thermal_state", F.thermal(s.power.thermalState)),
            ("gpu_heat_capped_percent", s.gpuDetail?.thermalLimited.map(F.r1)),
            ("cpu_speed_limit_percent", limits?.cpuSpeedLimit.map(JSON.int) ?? F.unavailable("pmset is read only while the Thermals tab is open")),
            ("cpu_scheduler_limit_percent", limits?.cpuSchedulerLimit.map(JSON.int)),
            ("thermal_warning_level", limits.map { $0.thermalWarningRecorded ? ($0.thermalWarningLevel.map(JSON.int) ?? .null) : .str("none recorded") }),
            ("pmset_read_at", t?.limitsAt.map(F.time)),
            ("throttled_this_session", t.map { F.duration($0.throttledSeconds) }),
            ("observed", t.map { F.duration($0.observedSeconds) }),
        ])
        return object([
            ("summary", .str(catalog.families.map { "\($0.family.short) \(Int($0.max.rounded())) °C" }.joined(separator: " · "))),
            ("sensor_count", .int(catalog.sensors.count)),
            ("highest_by_group", .object(highest)),
            ("groups", .object(groups)),
            ("fans", fans),
            ("throttling", throttling),
        ])
    }
}
