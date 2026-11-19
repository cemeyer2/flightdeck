import Foundation
// Output of the read-only `camera_mic` MCP tool: whether a camera or microphone is in use now and by which app, then
// the recent sessions (newest first) with how each app was identified, and per-app totals. Attribution confidence is
// always given, so a model never reports a guess ("likely") or an unknown app as fact.

extension MCPTools {
    func cameraMic(_ a: Args) async throws -> JSON {
        let days = try a.int("days", default: 7, 1...CameraMicStore.retentionDays)
        let limit = try a.int("limit", default: 50, 1...500)
        guard let src = await source.cameraMic() else {
            return object([("summary", F.unavailable("Camera & Mic history is kept by the FlightDeck app"))])
        }
        let now = self.now()
        let sessions = src.store.sessions(since: now.addingTimeInterval(-Double(days) * 86_400)).sorted { $0.start > $1.start }
        let firstSeen = src.store.firstSeen

        func live(_ k: SensorKind) -> JSON {
            guard let l = src.live else { return F.unavailable("not watched") }
            let open = l.open.filter { $0.kind == k }
            return .object(dropping: [
                ("in_use", .bool(l.inUse(k))),
                ("devices", .strings((l.running[k] ?? []).map(\.label))),
                // Standalone: one device reading, no tracker, so there are no open sessions to name the app from.
                ("apps", l.since == nil ? (l.inUse(k) ? F.unavailable("the FlightDeck app isn't running, so the app isn't known") : nil)
                                        : .array(open.map(appJSON))),
            ])
        }
        func appJSON(_ s: SensorSession) -> JSON {
            .object(dropping: [("app", .str(s.appLabel)), ("bundle_id", s.app?.bundleID.map(JSON.str)), ("path", s.app?.path.map(JSON.str)),
                               ("pid", s.app?.pid.map { .int(Int($0)) }), ("attribution", .str(s.confidence.rawValue)), ("how", .str(s.how)),
                               ("since", F.time(s.start)), ("since_is_lower_bound", s.startObserved ? nil : .bool(true))])
        }
        func sessionJSON(_ s: SensorSession) -> JSON {
            .object(dropping: [
                ("kind", .str(s.kind.rawValue)), ("app", .str(s.appLabel)), ("bundle_id", s.app?.bundleID.map(JSON.str)),
                ("path", s.app?.path.map(JSON.str)), ("attribution", .str(s.confidence.rawValue)), ("how", .str(s.how)),
                ("devices", .strings(s.devices)), ("start", F.time(s.start)),
                ("end", s.end.map(F.time) ?? .str("still in use")), ("duration", F.duration(s.duration(now: now))),
                ("started_before_watching", s.startObserved ? nil : .bool(true)),
                ("ended_when_flightdeck_stopped", s.endObserved ? nil : .bool(true)),
                ("first_use", s.firstUse ? .bool(true) : nil), ("unusual_hour", s.atUnusualHour() ? .bool(true) : nil),
                ("while_screen_locked", s.whileLocked ? .bool(true) : nil), ("while_idle", s.whileIdle ? .bool(true) : nil),
            ])
        }
        // Per app and kind over the window: sessions, total time, first seen.
        var totals: [String: (s: SensorSession, n: Int, secs: TimeInterval)] = [:]
        for s in sessions {
            let k = s.kind.rawValue + "|" + (s.app.map { s.confidence == .confirmed ? $0.key : "?" + $0.key } ?? "?")
            totals[k, default: (s, 0, 0)].n += 1
            totals[k, default: (s, 0, 0)].secs += s.duration(now: now)
        }
        let byApp: [JSON] = totals.sorted { $0.value.secs > $1.value.secs }.map { k, v in
            .object(dropping: [("kind", .str(v.s.kind.rawValue)), ("app", .str(v.s.appLabel)), ("attribution", .str(v.s.confidence.rawValue)),
                               ("sessions", .int(v.n)), ("total", F.duration(v.secs)),
                               ("first_seen", v.s.app.flatMap { firstSeen[CameraMicTracker.knownKey(v.s.kind, $0)] }.map(F.time))])
        }
        let l = src.live
        let summary: String
        if let l {
            let parts = SensorKind.allCases.map { k -> String in
                guard l.inUse(k) else { return "\(k.title) not in use" }
                let apps = l.open.filter { $0.kind == k }.map(\.appLabel)
                return "\(k.title) in use" + (apps.isEmpty ? "" : " by " + apps.joined(separator: ", "))
            }
            summary = parts.joined(separator: "; ") + ". \(sessions.count) session\(sessions.count == 1 ? "" : "s") in the last \(days) day\(days == 1 ? "" : "s")."
        } else {
            summary = "\(sessions.count) sessions in the last \(days) days."
        }
        return object([
            ("summary", .str(summary)),
            ("camera", live(.camera)), ("microphone", live(.microphone)),
            ("per_process_microphone_state", l.map { .bool($0.perProcessAudio) }),
            ("sessions", .array(sessions.prefix(limit).map(sessionJSON))),
            ("sessions_omitted", sessions.count > limit ? .int(sessions.count - limit) : nil),
            ("by_app", .array(byApp)),
            ("note", .str("Only device use is recorded (device, app, times), never audio or video. History stays on this Mac for \(CameraMicStore.retentionDays) days. attribution: confirmed = macOS named the app; likely = a guess (the app in front when the device came on); unknown = nobody said.")),
        ])
    }
}
