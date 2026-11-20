import Foundation
// The FlightDeck MCP tools: their schemas (what `tools/list` shows a model) and the argument handling around them.
// The output of each tool is built in MCPToolOutput.swift (and the files it names). Every tool reads the Mac without
// changing it. `sample_stacks` runs Apple's `sample` on one of the user's own processes for at most 5 seconds, and
// `mark` writes one thing: FlightDeck's own marks file (Marks.swift), so a coding agent can measure its work later.
//
// Output conventions, chosen for models reading it: compact JSON, summary first and details after; sizes and rates as
// short human strings ("1.2 GB", "3.4 MB/s"); percentages as numbers rounded to 0.1. A value FlightDeck could not
// measure is written as "unavailable (reason)" or null in a table, never as 0 (see Measured.swift).

public struct MCPTools: MCPToolProvider {
    let source: MCPDataSource
    /// Injection points for tests; the defaults are the real readers.
    var now: @Sendable () -> Date = { Date() }
    var stackSampler: @Sendable (Int32, Int) -> String = { ProcessInspector.sampleStacks(pid: $0, seconds: $1) }
    var inspector: @Sendable (Int32, String) -> ProcessDetails = { ProcessInspector.details(pid: $0, path: $1) }
    var ownUID: UInt32 = getuid()
    /// The battery's condition from system_profiler (~1 s); tests replace it so they never read the machine.
    var batteryCondition: @Sendable () -> String? = {
        Shell.run("/usr/sbin/system_profiler", ["-json", "SPPowerDataType"], timeout: 20).flatMap { CheckupParse.battery(Data($0.utf8))?.condition }
    }
    /// Where `mark` stores marks (FlightDeck's own file, shared by the app and `--mcp`); tests use a temporary one.
    var marks = MarkStore()
    /// Runs `log show` for `process_logs`; tests replay captured ndjson instead.
    var logRunner: @Sendable (ProcessLogs.Query) -> ProcessLogs.Result = { ProcessLogs.read($0) }

    public init(source: MCPDataSource) { self.source = source }

    /// Shown to the model on `initialize` / `server/discover`.
    public static let instructions = """
    FlightDeck is a macOS system monitor. Start with get_status for "why is my Mac slow / hot / loud / draining?": it \
    returns plain-English findings, the system's numbers, the top apps and which apps strain which subsystem. Then drill \
    down with list_processes, get_process and sample_stacks (why a process of the user's is busy or hung), history (the \
    black box: statistics over the last minutes or hours), recent_incidents (the Flight Log), diagnostic_reports (crashes \
    and hangs), checkup (health and security checklist), temperatures (every sensor, fans, throttling), wifi (the Wi-Fi link's health and the last nearby-network scan), trends (daily history, before/after app and macOS updates) and \
    camera_mic (which apps used the camera or microphone, and when), network_destinations (which hosts each app talked to), \
    battery (health forecast and what's wearing the battery), restarts (boots, how each previous session ended, \
    boot and login time), panics (kernel panic reports with the likely culprit) and peripherals (USB/Thunderbolt link \
    speeds with why a device runs slower than it could, and accessory battery levels with time left). \
    To measure your own work (a build, a test run, a benchmark): call mark before and after it, then measure between \
    the two marks, optionally with process or app for that process tree's cost and compare_to for a baseline run \
    (see the measure_change prompt). query_metrics returns raw black-box time series; process_logs returns a process's \
    unified-log messages. All tools are read-only except mark, which only adds to FlightDeck's own marks file. Values FlightDeck could not measure are marked "unavailable", never reported as 0.
    """

    struct ArgError: Error { var message: String }

    /// Typed access to `arguments` with range checks; errors become tool errors the model can read and correct.
    struct Args {
        let j: JSON
        func int(_ k: String, default d: Int, _ range: ClosedRange<Int>) throws -> Int {
            guard let v = j[k], v != .null else { return d }
            guard let i = v.int else { throw ArgError(message: "\(k) must be an integer") }
            guard range.contains(i) else { throw ArgError(message: "\(k) must be between \(range.lowerBound) and \(range.upperBound)") }
            return i
        }
        func requiredInt(_ k: String) throws -> Int {
            guard let i = j[k]?.int else { throw ArgError(message: "\(k) is required and must be an integer") }
            return i
        }
        func string(_ k: String) throws -> String? {
            guard let v = j[k], v != .null else { return nil }
            guard let s = v.string else { throw ArgError(message: "\(k) must be a string") }
            return s
        }
        func bool(_ k: String) throws -> Bool {
            guard let v = j[k], v != .null else { return false }
            guard let b = v.bool else { throw ArgError(message: "\(k) must be true or false") }
            return b
        }
        func choice(_ k: String, _ allowed: [String], default d: String) throws -> String {
            guard let s = try string(k) else { return d }
            guard allowed.contains(s) else { throw ArgError(message: "\(k) must be one of: \(allowed.joined(separator: ", "))") }
            return s
        }
        func choices(_ k: String, _ allowed: [String]) throws -> [String] {
            guard let v = j[k], v != .null else { return [] }
            guard let a = v.array?.compactMap(\.string), a.count == v.array?.count, a.allSatisfy(allowed.contains) else {
                throw ArgError(message: "\(k) must be an array of: \(allowed.joined(separator: ", "))")
            }
            return a
        }
    }

    public func call(_ name: String, arguments: JSON) async -> MCPToolResult {
        let a = Args(j: arguments)
        do {
            let out: JSON
            switch name {
            case "get_status": out = try await getStatus()
            case "list_processes": out = try await listProcesses(a)
            case "get_process": out = try await getProcess(a)
            case "sample_stacks": out = try await sampleStacks(a)
            case "recent_incidents": out = try await recentIncidents(a)
            case "diagnostic_reports": out = try await diagnosticReports(a)
            case "history": out = try await history(a)
            case "checkup": out = try await checkup()
            case "trends": out = try await trends(a)
            case "temperatures": out = try await temperatures()
            case "wifi": out = try await wifi()
            case "camera_mic": out = try await cameraMic(a)
            case "battery": out = try await battery()
            case "network_destinations": out = try await networkDestinations(a)
            case "restarts": out = try await restarts(a)
            case "panics": out = try await panics(a)
            case "peripherals": out = try await peripherals()
            case "mark": out = try await mark(a)
            case "marks": out = try await listMarks(a)
            case "measure": out = try await measure(a)
            case "query_metrics": out = try await queryMetrics(a)
            case "process_logs": out = try await processLogs(a)
            default: return .error("Unknown tool \(name)")
            }
            return MCPToolResult(text: out.text)
        } catch let e as ArgError {
            return .error("Invalid arguments: \(e.message)")
        } catch {
            return .error("\(error)")
        }
    }

    // MARK: Schemas

    static func schema(_ props: [(String, JSON)], required: [String] = []) -> JSON {
        ["type": "object", "properties": .object(props), "required": required.isEmpty ? nil : .strings(required), "additionalProperties": false]
    }
    static func int(_ desc: String, _ min: Int, _ max: Int, _ def: Int? = nil) -> JSON {
        ["type": "integer", "description": .str(desc), "minimum": .int(min), "maximum": .int(max), "default": def.map(JSON.int)]
    }
    static func enumeration(_ desc: String, _ values: [String], _ def: String? = nil) -> JSON {
        ["type": "string", "description": .str(desc), "enum": .strings(values), "default": def.map(JSON.str)]
    }

    static let processSorts = ["cpu", "memory", "energy", "gpu", "disk", "network", "wakeups", "threads", "pid", "name"]
    static let reportKinds = ["crash", "hang", "jetsam", "panic", "fault", "cpu_limit", "disk_writes", "wakeups", "other"]
    static let processSections = ["arguments", "files", "sockets", "threads"]

    public var specs: [MCPToolSpec] {
        [
            MCPToolSpec(name: "get_status", title: "System status",
                        description: "One-call overview of this Mac right now: plain-English findings (what's wrong), CPU, memory, swap, disk, network, power, thermal and GPU numbers, the top apps by CPU, memory and energy, and the Stress Map's top causes of 'misery' per subsystem. Call this first.",
                        inputSchema: Self.schema([])),
            MCPToolSpec(name: "list_processes", title: "List processes",
                        description: "Running processes (or apps, with helpers rolled into their app) as a compact table, sorted and filtered. CPU % is of one core (can exceed 100). null = not measurable (e.g. another user's process).",
                        inputSchema: Self.schema([
                            ("sort", Self.enumeration("Column to sort by, largest first (name and pid ascending).", Self.processSorts, "cpu")),
                            ("limit", Self.int("Rows to return.", 1, 100, 20)),
                            ("filter", ["type": "string", "description": "FlightDeck query: space-separated terms, all must match. Examples: 'cpu>50', 'mem>1g', 'user:root', 'app:chrome', 'gpu>0', 'wakeups>500', 'hung', 'sleep' (keeps the Mac awake), 'kind:intel', or plain text matching name/path/user/PID."]),
                            ("by_app", ["type": "boolean", "description": "Group processes into apps.", "default": false]),
                        ])),
            MCPToolSpec(name: "get_process", title: "Process details",
                        description: "Details of one process by PID: identity, path, user, parent chain, start time, CPU, memory, energy, disk and network, listening ports, open-file and socket counts, code signature. Optional sections add more; other users' processes show 'unavailable' where macOS refuses.",
                        inputSchema: Self.schema([
                            ("pid", ["type": "integer", "description": "Process ID."]),
                            ("include", ["type": "array", "description": "Extra sections: arguments (command line), files (open file descriptors), sockets, threads.",
                                         "items": ["type": "string", "enum": .strings(Self.processSections)]]),
                        ], required: ["pid"])),
            MCPToolSpec(name: "sample_stacks", title: "Sample call stacks",
                        description: "Samples a process's call stacks with Apple's /usr/bin/sample for 1-5 seconds (default 3; the call blocks that long) and returns a one-line summary of where the main thread spends its time plus its heaviest call path. Use it to explain why an app is busy or not responding. Only the user's own processes. Read-only, but it briefly attaches to the process.",
                        inputSchema: Self.schema([
                            ("pid", ["type": "integer", "description": "Process ID (must belong to the current user)."]),
                            ("seconds", Self.int("How long to sample.", 1, 5, 3)),
                        ], required: ["pid"])),
            MCPToolSpec(name: "recent_incidents", title: "Flight Log incidents",
                        description: "FlightDeck's Flight Log: problems that lasted 20 s or more (CPU hogs, memory pressure, hangs, heat, heavy I/O…), newest first, with start, duration and any captured stack summary. Kept 7 days; recorded while the FlightDeck app runs.",
                        inputSchema: Self.schema([
                            ("hours", Self.int("How far back to look.", 1, 168, 24)),
                            ("limit", Self.int("Incidents to return.", 1, 100, 20)),
                            ("min_severity", Self.enumeration("Lowest severity to include.", ["info", "caution", "warning"], "info")),
                        ])),
            MCPToolSpec(name: "diagnostic_reports", title: "macOS crash and hang reports",
                        description: "macOS's own diagnostic reports: crashes (with exception type), hangs, memory kills (jetsam), kernel panics, and CPU, disk-write and wake-up limit violations, newest first, with counts by kind and by process. Up to 7 days.",
                        inputSchema: Self.schema([
                            ("hours", Self.int("How far back to look.", 1, 168, 24)),
                            ("kind", Self.enumeration("Only this kind of report.", Self.reportKinds)),
                            ("process", ["type": "string", "description": "Only reports whose process name contains this (case-insensitive)."]),
                            ("limit", Self.int("Reports to list.", 1, 100, 20)),
                        ])),
            MCPToolSpec(name: "history", title: "Black-box history",
                        description: "Statistics from FlightDeck's always-on black box over the last N minutes: average, 95th percentile and peak of CPU, memory pressure, swap, disk, network, power, temperature and GPU; top apps by average CPU and peak memory; and the problems found in that window. Every sample for the last hour, one per 10 s for 24 hours.",
                        inputSchema: Self.schema([("minutes", Self.int("Window length, ending now.", 1, 1440, 60))])),
            MCPToolSpec(name: "checkup", title: "Health checkup",
                        description: "FlightDeck's health and security checklist: SIP, FileVault, Gatekeeper, firewall, updates, Time Machine, free space, drive and battery health, recent crashes and hangs, uptime, swap trend, login items, extensions. Items needing attention first. Takes a few seconds.",
                        inputSchema: Self.schema([])),
            MCPToolSpec(name: "trends", title: "Daily trends",
                        description: "FlightDeck's daily history (up to 90 days): per-day CPU, memory pressure, swap, energy, temperature, sleep, crashes, hangs and incidents, plus macOS and app updates in the window with a before/after comparison of each. With app, that app's per-day CPU, memory and energy instead. Days FlightDeck didn't run are absent.",
                        inputSchema: Self.schema([
                            ("days", Self.int("Days to include, ending today.", 1, 90, 7)),
                            ("app", ["type": "string", "description": "App name (e.g. 'Safari') to show that app's days."]),
                        ])),
            MCPToolSpec(name: "temperatures", title: "Temperatures, fans and throttling",
                        description: "Every temperature sensor with a friendly name, grouped (CPU performance/efficiency cores, GPU, SoC, SSD, battery, Wi-Fi, palm rest, airflow…), each with now/min/average/max since FlightDeck started; the hottest sensor per group; fans with RPM against target, min and max and any fan problem; and whether macOS is slowing the Mac down for heat (pmset CPU speed limit, thermal pressure, GPU heat cap) with time spent throttled. Temperatures in °C.",
                        inputSchema: Self.schema([])),
            MCPToolSpec(name: "wifi", title: "Wi-Fi link and nearby networks",
                        description: "The current Wi-Fi link (signal, noise, SNR, link rate against the maximum for its standard and width, band, channel, width, security) with plain-English health ratings and reasons a link rate may be low; and a summary of the last nearby-network scan the user ran in the app (networks per band, busiest channels, the strongest networks, a channel recommendation). Never scans. SSIDs and BSSIDs only with Location Services permission.",
                        inputSchema: Self.schema([])),
            MCPToolSpec(name: "camera_mic", title: "Camera and microphone use",
                        description: "Privacy watch: whether a camera or microphone is in use right now and by which app, then recent sessions (newest first) with device, app, start, end and duration, how the app was identified (confirmed / likely / unknown, never guessed silently), and flags for an app's first use, unusual hours (midnight to 6 a.m.) and use while the screen was locked or the Mac idle. Only device use is recorded, never audio or video.",
                        inputSchema: Self.schema([
                            ("days", Self.int("Days of history to include, ending now.", 1, 90, 7)),
                            ("limit", Self.int("Most sessions to list.", 1, 500, 50)),
                        ])),
            MCPToolSpec(name: "battery", title: "Battery health forecast and wear",
                        description: "The battery's facts now (charge, health %, cycles against the design count, capacities, temperature, condition, the gauge's lifetime extremes), a service status, a forecast of when health reaches 80% (Theil–Sen trend with a 95% range, from FlightDeck's daily history and up to ~10 days seeded from macOS's power log) or exactly what data is missing, and the known ageing factors measured from FlightDeck's samples: time at high charge while plugged in, heat, deep discharges, cycles per week and charge-limit / Optimized Charging holds, each with a tip. Desktops report no battery.",
                        inputSchema: Self.schema([])),
            MCPToolSpec(name: "network_destinations", title: "Network destinations per app",
                        description: "Who each app talks to: per app, the remote hosts it exchanged traffic with over the last N days (busiest first), grouped by registrable domain of the reverse-DNS name (or by IP when there is none), with bytes in and out, connection count, first and last seen, ports/services, local-network vs internet, and flags for a destination new to the app in the last 24 h or unusual volume today. Name sources are labelled; traffic between nettop samples is missed. Recorded only while the FlightDeck app runs, on this Mac.",
                        inputSchema: Self.schema([
                            ("app", ["type": "string", "description": "Only apps whose name (or bundle path) contains this, case-insensitive."]),
                            ("destination", ["type": "string", "description": "Only destinations whose domain, host name or IP contains this (which apps talked to X)."]),
                            ("days", Self.int("Days to include, ending today.", 1, 30, 7)),
                            ("limit", Self.int("Most apps, and most destinations per app, to list.", 1, 200, 20)),
                        ])),
            MCPToolSpec(name: "restarts", title: "Restarts and shutdowns",
                        description: "Every boot in the window, newest first, with how the session before it ended (clean, unexpected, kernel panic or unknown), a plain-English explanation, the kernel's shutdown cause code when FlightDeck saved one (codes are undocumented by Apple; certainty is given), the evidence and whether the verdict is inferred; counts by cause; boot and login timing (kernel to login window, login to desktop, login items, busiest processes after login); recent app hangs; and what the records can't tell. Read-only; doesn't query the unified log.",
                        inputSchema: Self.schema([("days", Self.int("Days of boots to include, ending now.", 1, 90, 30))])),
            MCPToolSpec(name: "panics", title: "Kernel panics",
                        description: "Kernel panic reports from /Library/Logs/DiagnosticReports and its Retired folder, newest first: time, plain-English culprit (third-party driver, hung app or service, system hang, sleep/wake, hardware, memory, graphics, kernel), what to do, the panic string, panicked task and the kernel extensions in the backtrace.",
                        inputSchema: Self.schema([("days", Self.int("Days to look back.", 1, 90, 90))])),
            MCPToolSpec(name: "peripherals", title: "Peripherals: link speeds and accessory batteries",
                        description: "Every USB and Thunderbolt/USB4 device with its negotiated link speed, what the device supports, what its port or hub supports, hubs in the chain, a drive's realistic maximum MB/s, and a plain-English diagnosis when it's linked slower than both ends could (e.g. an SSD stuck at USB 2 behind a USB 2-only cable or hub, a dock at 20 Gb/s instead of 40). Plus accessory batteries (Magic Mouse/Keyboard/Trackpad, AirPods per bud and case where macOS reports them) with an estimate of the time left from FlightDeck's saved history. Inferred capabilities are flagged. Takes about a second (one system_profiler call).",
                        inputSchema: Self.schema([])),
        ] + Self.agentSpecs
    }
}

/// Number and value formatting for tool output.
enum MCPFormat {
    static func r1(_ d: Double) -> JSON { .double((d * 10).rounded() / 10) }
    static func r2(_ d: Double) -> JSON { .double((d * 100).rounded() / 100) }
    static func unavailable(_ reason: String) -> JSON { .string("unavailable (\(reason))") }
    /// A measured value through `f`, or "unavailable (reason)".
    static func m(_ x: Measured<Double>, _ f: (Double) -> JSON = r1) -> JSON {
        switch x { case .value(let v): return f(v); case .unavailable(let r): return unavailable(r) }
    }
    static func bytes(_ b: Double) -> JSON { .string(Fmt.bytes(b)) }
    static func rate(_ b: Double) -> JSON { .string(Fmt.rate(b)) }
    /// Local time with offset, to the second, so the model can relate times to what the user says ("at 3 pm").
    static func time(_ d: Date) -> JSON {
        let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]
        return .string(f.string(from: d))
    }
    /// "45 s", "12 min", "3.5 h".
    static func duration(_ s: TimeInterval) -> JSON {
        if s < 90 { return .string("\(Int(s.rounded())) s") }
        if s < 5400 { return .string("\(Int((s / 60).rounded())) min") }
        return .string(String(format: "%.1f h", s / 3600))
    }
    static func severity(_ s: Finding.Severity) -> JSON { switch s { case .info: "info"; case .caution: "caution"; case .warning: "warning" } }
    static let thermalStates = ["nominal", "fair", "serious", "critical"]
    static func thermal(_ i: Int) -> JSON { .string(thermalStates[min(max(i, 0), 3)]) }
}
