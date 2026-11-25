import Foundation
// Output of the read-only `backups` MCP tool: Time Machine's state now, each destination, recent runs (from what
// FlightDeck saved from the unified log), completed backups and gaps. It reads the settings file and tmutil (fast,
// nothing mounted) but never runs `log show` and never writes FlightDeck's backup history.

extension MCPTools {
    func backups(_ a: Args) async throws -> JSON {
        let days = try a.int("days", default: 30, 1...90)
        let r = await Task.detached(priority: .utility) {
            BackupsCollector.collect(store: BackupStore(dir: BackupStore.defaultDirectory, readOnly: true), scanLog: false)
        }.value
        return withHelper(Self.backupsJSON(r, days: days, now: now()), await source.helperAccess())
    }

    static func runJSON(_ run: BackupRun) -> JSON {
        var outcome = "unfinished (no outcome logged: still running, or the log rotated)", reason: JSON? = nil
        switch run.outcome {
        case .succeeded: outcome = "succeeded"
        case .failed(let name, _):
            outcome = "failed"
            let e = BackupFailures.explain(name)
            reason = .object(dropping: [("code", .str(name)), ("title", .str(e.title)), ("explanation", .str(e.detail)), ("fix", e.fix.map(JSON.str))])
        case .unfinished: break
        }
        return .object(dropping: [
            ("started", run.startSeen ? F.time(run.start) : nil), ("ended", run.end.map(F.time)), ("outcome", .str(outcome)), ("reason", reason),
            ("destination", run.destinationName.map(JSON.str)),
            ("duration", run.duration.map(F.duration) ?? run.elapsedText.map { .str("\($0) (backupd's estimate)") }),
            ("copied", run.bytesCopied.map { .str(Fmt.storage($0)) }), ("mode", run.mode.map(JSON.str)),
        ])
    }

    static func backupsJSON(_ r: BackupsReport, days: Int, now: Date) -> JSON {
        let cut = now.addingTimeInterval(-Double(days) * 86_400)
        let runs = r.runs.filter { $0.start >= cut }
        let last = r.lastSuccess
        var summary = "Time Machine: \(r.state.rawValue.lowercased())."
        if let last { summary += " Last successful backup \(last.formatted(date: .abbreviated, time: .shortened))." }
        else if !r.destinations.isEmpty { summary += " No completed backup is known." }
        if let g = r.ongoingGap { summary += " No successful backup for \(Int(g.length / 86_400)) days." }
        let fails = runs.filter { if case .failed = $0.outcome { true } else { false } }
        if !fails.isEmpty { summary += " \(fails.count) failed run\(fails.count == 1 ? "" : "s") in the last \(days) days." }
        let status: JSON? = r.status.map { s in
            .object(dropping: [
                ("running", .bool(s.running)), ("phase", s.running ? .str(s.phaseTitle) : nil),
                ("percent", s.fraction.map { MCPFormat.r1($0 * 100) }), ("copied", s.bytesCopied.map { .str(Fmt.storage($0)) }),
                ("total", s.totalBytes.map { .str(Fmt.storage($0)) }), ("time_remaining", s.timeRemaining.map(F.duration)),
                ("destination", s.destinationID.flatMap { id in r.destinations.first { $0.id == id }?.name }.map(JSON.str)),
            ])
        }
        let dests: [JSON] = r.destinations.map { d in
            .object(dropping: [
                ("name", .str(d.name)), ("kind", d.kind.map { .str($0.rawValue.lowercased()) }), ("address", d.address.map(JSON.str)),
                ("last_used", d.isLast ? .bool(true) : nil), ("backing_up_now", d.backingUpNow ? .bool(true) : nil),
                ("free", d.bytesAvailable.map { .str(Fmt.storage($0)) } ?? MCPFormat.unavailable("not in Time Machine's settings")),
                ("used", d.bytesUsed.map { .str(Fmt.storage($0)) }),
                ("free_space_change_per_week", d.freeSpacePerDay.map { .str(Fmt.storage($0 * 7)) }),
                ("last_successful_backup", d.lastSuccess.map(F.time)), ("last_attempt", d.lastAttempt.map(F.time)),
                ("backups_kept", .int(d.backupsKept)), ("oldest_backup", d.oldestBackup.map(F.time)),
                ("last_result_code", d.lastResult.flatMap { $0 == 0 ? nil : .int($0) }),
                ("encrypted", d.encrypted.map(JSON.bool)), ("last_verified", d.lastVerified.map(F.time)),
            ])
        }
        let gaps: [JSON] = r.gaps.filter { ($0.to ?? now) >= cut }.map { g in
            .object(dropping: [("from", g.from.map(F.time)), ("to", g.to.map(F.time)), ("ongoing", g.ongoing ? .bool(true) : nil), ("length", F.duration(g.length))])
        }
        let snaps: JSON = r.snapshots.map { s in
            .object([("count", .int(s.count)), ("time_machine", .int(s.filter { $0.kind == .timeMachine }.count)),
                     ("size", MCPFormat.unavailable("macOS reports snapshot sizes only to administrators"))])
        } ?? MCPFormat.unavailable(r.snapshotNote ?? "tmutil couldn't list them")
        return .object(dropping: [
            ("summary", .str(summary)), ("state", .str(r.state.rawValue)), ("automatic_backups", r.autoBackup.map(JSON.bool)),
            ("interval", r.interval.map(F.duration)), ("status_now", status), ("destinations", .array(dests)),
            ("runs", .array(runs.prefix(50).map(runJSON))),
            ("completed_backups_in_window", .int(r.successes.filter { $0 >= cut }.count)),
            ("gap_threshold", F.duration(r.gapThreshold)), ("gaps", .array(gaps)),
            ("local_snapshots", snaps), ("limits", .strings(r.limits)),
        ])
    }
}
