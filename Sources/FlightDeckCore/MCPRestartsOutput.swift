import Foundation
// Output of the read-only `restarts` and `panics` MCP tools. They read the same no-root sources as the Restarts &
// Crashes page (wtmp, logd's shutdown log, the power log, panic and hang reports, FlightDeck's saved boot history),
// but never query the unified log: shutdown cause codes are the ones FlightDeck already saved. Inferred verdicts and
// undocumented cause codes are flagged so a model doesn't state them as fact.

extension MCPTools {
    func restarts(_ a: Args) async throws -> JSON {
        let days = try a.int("days", default: 30, 1...90)
        let r = await Task.detached(priority: .utility) { RestartsCollector.collect(store: BootStore(dir: DailyLog.defaultDirectory, readOnly: true), queryLog: .none) }.value
        return Self.restartsJSON(r, days: days, now: now())
    }

    func panics(_ a: Args) async throws -> JSON {
        let days = try a.int("days", default: 90, 1...90)
        let now = self.now()
        let list = await Task.detached(priority: .utility) { PanicReports.scan(since: now.addingTimeInterval(-Double(days) * 86_400)) }.value
        return Self.panicsJSON(list)
    }

    static func verdictJSON(_ v: ShutdownVerdict) -> JSON {
        .object(dropping: [
            ("kind", .str(v.kind.rawValue.lowercased())), ("title", .str(v.title)), ("explanation", .str(v.detail)),
            ("cause_code", v.cause.map { .int($0.code) }), ("cause_certainty", v.cause.map { .str($0.certainty.rawValue) }),
            ("panic_report", v.panic.map { .str(($0.path as NSString).lastPathComponent) }),
            ("evidence", .strings(v.evidence)), ("inferred", v.inferred ? .bool(true) : nil),
        ])
    }

    static func restartsJSON(_ r: RestartsReport, days: Int, now: Date) -> JSON {
        let events = r.events.filter { now.timeIntervalSince($0.boot) <= Double(days) * 86_400 }
        let bad = events.filter(\.previous.isUnexpected)
        let summary = "\(events.count) boots in the last \(days) days; \(bad.count) after an unexpected shutdown or panic"
            + (bad.first.map { " (latest: \($0.previous.title), before the boot at \($0.boot.formatted(date: .abbreviated, time: .shortened)))" } ?? "") + "."
        func timing(_ t: BootTiming) -> JSON {
            .object(dropping: [
                ("kernel_to_login_window", t.toLoginWindow.map(F.duration)), ("at_login_window", t.atLoginWindow.map(F.duration)),
                ("login_to_desktop", t.loginToDesktop.map(F.duration)), ("login_items_phase", t.itemsPhase.map(F.duration)),
                ("boot_to_desktop", t.bootToDesktop.map(F.duration)),
                ("login_items", .strings(t.items.prefix(20).map { "\($0.name) (\($0.kind), +\(Int($0.startedAfterLogin)) s)" })),
                ("busiest_after_login", t.busiest.isEmpty ? nil : .strings(t.busiest.map { "\($0.name): \(Int(($0.cpuSeconds ?? 0).rounded())) s CPU" })),
                ("busiest_source", t.busiestSource.map { .str($0.rawValue) }),
                ("precision", .str("process launch times, to the second; the login-window phase includes typing the password")),
            ])
        }
        let saved = Dictionary(r.history.map { (Int($0.boot.timeIntervalSince1970 / 60), $0) }, uniquingKeysWith: { a, _ in a })
        return .object(dropping: [
            ("summary", .str(summary)),
            ("current_boot", r.current.map { t in .object(dropping: [("booted", F.time(t.boot)), ("timing", timing(t))]) }),
            ("boots", .array(events.map { e in
                .object(dropping: [
                    ("boot", F.time(e.boot)), ("previous_session_ended", verdictJSON(e.previous)),
                    ("uptime_before", e.previousBoot.map { F.duration(e.boot.timeIntervalSince($0)) }),
                    ("boot_to_login", e.login.map { F.duration($0.timeIntervalSince(e.boot)) }),
                    ("saved_timing", saved[Int(e.boot.timeIntervalSince1970 / 60)]?.timing.flatMap { $0.boot == r.current?.boot ? nil : timing($0) }),
                ])
            })),
            ("by_cause", .array(BootHistory.grouped(events).map { .object([("title", .str($0.title)), ("kind", .str($0.kind.rawValue.lowercased())), ("count", .int($0.count))]) })),
            ("app_hangs_30_days", .strings(r.hangs.prefix(20).map { "\($0.process) at \($0.time.formatted(date: .abbreviated, time: .shortened))" + ($0.summary.map { ", \($0)" } ?? "") })),
            ("limits", .strings(r.limits)),
        ])
    }

    static func panicsJSON(_ list: [PanicReport]) -> JSON {
        .object(dropping: [
            ("summary", .str(list.isEmpty ? "No kernel panic reports in /Library/Logs/DiagnosticReports (or Retired) in this window."
                                          : "\(list.count) kernel panic report\(list.count == 1 ? "" : "s"); latest: \(list[0].explanation)")),
            ("panics", .array(list.prefix(20).map { p in
                .object(dropping: [
                    ("time", F.time(p.time)), ("time_is", .str(p.timeIsPanic ? "panic" : "report written (after the restart)")),
                    ("culprit", .str(p.culprit.rawValue)), ("culprit_name", p.culpritName.map(JSON.str)),
                    ("explanation", .str(p.explanation)), ("panic_string", .str(p.headline)),
                    ("panicked_task", p.task.map(JSON.str)), ("kexts_in_backtrace", p.kexts.isEmpty ? nil : .strings(p.kexts)),
                    ("third_party_kexts", p.thirdPartyKexts.isEmpty ? nil : .strings(p.thirdPartyKexts)),
                    ("os_version", p.osVersion.map(JSON.str)), ("file", .str(p.path)),
                ])
            })),
        ])
    }
}
