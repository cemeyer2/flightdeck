import Foundation

// MCP prompts: guided investigations an assistant can run with FlightDeck's tools. Clients show them as commands
// (Claude Code lists them as /mcp__flightdeck__<name>); choosing one sends the assistant a ready-made instruction
// saying which tools to call, in what order, and how to report. They only orchestrate the read-only tools: none asks
// the assistant to change anything on the Mac without the user's say-so.

public struct MCPPrompt: Sendable {
    public struct Argument: Sendable { public var name: String, description: String, required: Bool }
    public var name: String
    public var title: String
    public var description: String
    public var arguments: [Argument] = []
    /// Builds the instruction from the arguments (already checked for required ones).
    var render: @Sendable ([String: String]) -> String
}

public enum MCPPrompts {
    /// Shared closing guidance, so every prompt reports the same way.
    static let reporting = """

        Report back in plain English: lead with the answer (what is wrong, or that nothing is), then the evidence \
        (numbers from the tools, with units), then what I can do about it, most effective first. Quote FlightDeck's own \
        findings where they exist. If a reading is unavailable, say so rather than guessing. Don't quit, kill or change \
        anything yourself; if an action would help, tell me what it is and why.
        """

    public static let all: [MCPPrompt] = [
        MCPPrompt(name: "triage", title: "What's wrong with my Mac?",
                  description: "Ranks every current problem across the Mac, then checks the top ones in detail.") { _ in
            """
                Something seems wrong with my Mac. Investigate with FlightDeck:
                1. Call triage. It ranks every current problem (CPU, memory, heat, disk, battery, network, Flight Log, \
                crashes, restarts), each with evidence and a "next" tool with its arguments.
                2. For the top three problems (or fewer), call the next tool exactly as given, to confirm and explain each.
                3. If triage finds nothing, say so with its readings, and call recent_incidents for the last 24 hours in case it was earlier.
                Rank your answer the same way: the most serious problem first, and whether each is still happening.
                """ + reporting
        },
        MCPPrompt(name: "diagnose_slow_mac", title: "Why is my Mac slow?",
                  description: "Finds what is making the Mac slow or unresponsive right now and recently.",
                  arguments: [.init(name: "minutes", description: "How far back to look (default 30)", required: false)]) { a in
            let m = min(max(a["minutes"].flatMap(Int.init) ?? 30, 1), 1440)
            return """
                My Mac feels slow. Investigate with FlightDeck:
                1. Call triage for the ranked problems, then get_status for the system readings and Stress Map top causes.
                2. Call list_processes sorted by cpu (limit 15), then by memory, to see the heaviest apps.
                3. Call history for the last \(m) minutes to see whether this is new or ongoing.
                4. Call recent_incidents for the last 24 hours, in case this has happened before.
                5. If an app is hung or pinning the CPU and it's one of mine, call sample_stacks on its busiest process.
                Decide which subsystem is the bottleneck (CPU, memory pressure and swap, disk, thermals, GPU) and which app causes it.
                """ + reporting
        },
        MCPPrompt(name: "investigate_app", title: "Investigate an app",
                  description: "Everything FlightDeck knows about one app: its current use, history, crashes and changes since updates.",
                  arguments: [.init(name: "app", description: "App or process name, e.g. Safari", required: true)]) { a in
            let app = a["app"] ?? ""
            return """
                Investigate the app "\(app)" with FlightDeck:
                1. Call list_processes with filter "app:\(app)" and by_app to see its processes and current CPU, memory, energy and network.
                2. Call get_process on its busiest process for details (path, signature, ports, open files).
                3. Call trends for "\(app)" to compare today with its usual days and check whether an update changed its behaviour.
                4. Call diagnostic_reports and recent_incidents, looking for crashes, hangs or findings that mention it.
                5. If it is hung or busy, call sample_stacks on its busiest process to see what it is doing.
                Tell me whether "\(app)" is behaving normally for this Mac, and if not, how and since when.
                """ + reporting
        },
        MCPPrompt(name: "battery_drain", title: "What's draining my battery?",
                  description: "Explains battery drain: which apps used the energy, and what kept the Mac awake.",
                  arguments: [.init(name: "hours", description: "How far back to look (default 3)", required: false)]) { a in
            let h = min(max(a["hours"].flatMap(Int.init) ?? 3, 1), 24)
            return """
                My battery is draining faster than I expect. Investigate with FlightDeck:
                1. Call get_status for the current power draw, battery state and findings (sleep blockers, energy-hungry apps).
                2. Call list_processes sorted by energy (limit 15).
                3. Call history for the last \(h * 60) minutes for average and peak power and the top apps.
                4. Call trends to compare today's energy use and battery health with recent days.
                Separate what is normal (screen, the work I'm doing) from what isn't (background apps, apps preventing sleep, runaway processes).
                """ + reporting
        },
        MCPPrompt(name: "thermal_check", title: "Why is it hot / why is the fan loud?",
                  description: "Connects temperatures, fan speed and throttling to the processes producing the heat.") { _ in
            """
            My Mac is hot or its fan is loud. Investigate with FlightDeck:
            1. Call get_status for temperatures, fan speed, thermal pressure, GPU load and findings.
            2. Call temperatures for every sensor by group, fan health and whether macOS is limiting the CPU for heat.
            3. Call list_processes sorted by cpu and by energy (limit 10 each).
            4. Call history for the last 30 minutes to see when it started and whether the Mac is being throttled.
            Tell me what is generating the heat, whether macOS is slowing the CPU or GPU to cope, and whether it's expected for the work being done.
            """ + reporting
        },
        MCPPrompt(name: "crash_triage", title: "Crashes and hangs",
                  description: "Summarises recent crashes, hangs and resource-limit reports and what they have in common.",
                  arguments: [.init(name: "app", description: "Only this app (optional)", required: false),
                              .init(name: "days", description: "How far back (default 7)", required: false)]) { a in
            // diagnostic_reports and recent_incidents look back at most 168 hours.
            let d = min(max(a["days"].flatMap(Int.init) ?? 7, 1), 7)
            let only = a["app"].map { " Focus on \"\($0)\"." } ?? ""
            return """
                Summarise what has crashed or hung on this Mac in the last \(d) days.\(only) Use FlightDeck:
                1. Call diagnostic_reports for the last \(d * 24) hours: crashes, hangs, memory kills, CPU and disk-write limits.
                2. Call recent_incidents for the same period for FlightDeck's own findings (hangs it saw, runaway apps).
                3. For a repeat offender that is running now, call get_process on it.
                Group the reports by app and kind, call out patterns (same app, same time of day, after an update), and say which ones matter.
                """ + reporting
        },
        MCPPrompt(name: "health_checkup", title: "Mac health checkup",
                  description: "A full checkup: security settings, updates, backups, disk, battery, stability and trends.") { _ in
            """
            Give my Mac a health checkup with FlightDeck:
            1. Call checkup for security settings, updates, Time Machine, disk space, drive and battery health and stability.
            2. Call trends for the last 30 days to spot anything getting worse (energy, memory, crashes, battery health).
            3. Call diagnostic_reports for the last 7 days.
            List what needs attention first, most important first, then briefly confirm what's fine.
            """ + reporting
        },
        MCPPrompt(name: "since_update", title: "Did an update make things worse?",
                  description: "Compares behaviour before and after recent macOS or app updates.",
                  arguments: [.init(name: "app", description: "Only this app (optional)", required: false)]) { a in
            let only = a["app"].map { " for \"\($0)\"" } ?? ""
            return """
                Check whether a recent macOS or app update\(only) made my Mac worse. Use FlightDeck:
                1. Call trends\(a["app"].map { " for \"\($0)\"" } ?? "") for the before/after comparisons around recent updates.
                2. Call diagnostic_reports for the last 168 hours to see whether crashes or hangs began after an update.
                Name each update that changed things, what changed (CPU, energy, memory, crashes, hangs) and by how much. If there isn't enough history yet, say how many more days are needed.
                """ + reporting
        },
        MCPPrompt(name: "measure_change", title: "Did my change make it slower or hungrier?",
                  description: "Measures a workload (build, tests, benchmark) before and after a change with marks, and compares the two runs.",
                  arguments: [.init(name: "command", description: "The workload to run, e.g. `swift test` or `npm run build`", required: true),
                              .init(name: "process", description: "Process name to attribute cost to, e.g. swift-build or node (optional; default the whole Mac)", required: false)]) { a in
            let cmd = a["command"] ?? ""
            let filter = a["process"].map { ", with process \"\($0)\"" } ?? ""
            // Unlike the other prompts, this one runs the user's own workload: the user asked for exactly that by
            // choosing it. FlightDeck itself still only reads (and writes its marks).
            return """
                Measure whether my change makes `\(cmd)` slower or hungrier, using FlightDeck's marks. FlightDeck's black box must be \
                recording (the app running); if mark says it isn't, stop and tell me.
                1. Baseline, without the change (ask me how to get the code without it if that isn't obvious, and tell me what you \
                did): call mark with label "baseline-start", run `\(cmd)`, then call mark with label "baseline-end".
                2. With the change applied: call mark with label "change-start", run `\(cmd)` again the same way, then call mark \
                with label "change-end".
                3. Call measure from "change-start" to "change-end"\(filter), with compare_to {"from": "baseline-start", "to": "baseline-end"}.
                4. If the verdict says slower or hungrier, call measure on each window without a filter to see whether something \
                else on the Mac (indexing, a browser, thermal throttling) was busy during one run but not the other, and \
                process_logs for the workload's process if it printed errors.
                Report: the verdict first, then a small table of duration, CPU-seconds, peak memory, energy and disk for both runs \
                with the change in %. Say which differences are within the noise band and whether background activity or \
                throttling makes the comparison unfair (if so, suggest re-running). One run each is a small sample: say so when \
                the differences are small. Leave my code as you found it.
                """ + reporting
        },
    ]

    static func find(_ name: String) -> MCPPrompt? { all.first { $0.name == name } }
}
