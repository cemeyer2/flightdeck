import Foundation
import FlightDeckHelperProtocol
// Output of the "right now" MCP tools: get_status, list_processes, get_process and sample_stacks. The history tools
// are in MCPHistoryOutput.swift. See MCPTools.swift for the formatting conventions.

extension MCPTools {
    typealias F = MCPFormat

    /// Where the data came from. Standalone answers say what they lack, so a model doesn't read "no incidents" as
    /// "nothing happened".
    var sourceInfo: [(String, JSON)] {
        source.standalone
            ? [("source", "standalone"), ("source_note", "The FlightDeck app's MCP server isn't reachable, so `FlightDeck --mcp` sampled this Mac itself. Findings are from its own samples only (sustained-for-minutes problems need the app); history and incidents are what the app recorded while it was running.")]
            : [("source", "FlightDeck app (live)")]
    }

    func object(_ pairs: [(String, JSON?)]) -> JSON { .object(dropping: sourceInfo.map { ($0.0, $0.1) } + pairs) }

    func noSample() -> ArgError { ArgError(message: "No sample is available yet; try again in a second.") }

    /// A restricted process (another user's) reports placeholder zeros when the kernel refused its counters.
    /// The kernel refused this process's task counters: CPU, threads, wake-ups and disk I/O are placeholders.
    /// Counters the root helper filled in are real readings, not placeholders.
    static func unreadable(_ p: ProcessSample) -> Bool { p.restricted && p.cpuTime == 0 && p.source != .helper }
    static func cpu(_ p: ProcessSample) -> Double? { unreadable(p) ? nil : p.cpu }
    static func memory(_ p: ProcessSample) -> Double? { p.restricted && p.memory == 0 && p.source != .helper ? nil : Double(p.memory) }

    static func finding(_ f: Finding, tabs: ChromeTabsView? = nil) -> JSON {
        ["severity": F.severity(f.severity), "title": .str(f.title), "detail": f.detail.map(JSON.str), "since": F.time(f.since),
         "pids": f.pids.map { .array($0.prefix(5).map { .int(Int($0)) }) },
         "chrome_tabs": f.pids.flatMap { tabs?.json(pids: $0) }]   // hosts only
    }

    // MARK: get_status

    func getStatus() async throws -> JSON {
        guard let s = await source.snapshot() else { throw noSample() }
        let findings = await source.findings().sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.since < $1.since }
        let tabs = await source.chromeTabs()
        let summary: String
        if let worst = findings.first {
            summary = "\(findings.count) finding\(findings.count == 1 ? "" : "s"); worst: \(worst.title)"
        } else {
            summary = "All systems normal: nothing is wrong right now."
        }
        let mem = s.memory
        var power: [(String, JSON?)] = [("system_watts", F.m(s.power.systemWatts)), ("source", .str(s.power.powerSource)),
                                        ("low_power_mode", .bool(s.power.lowPowerMode))]
        if let b = s.power.battery {
            power += [("battery_percent", F.r1(b.percent)), ("charging", .bool(b.isCharging)),
                      ("battery_health_percent", b.health.map(F.r1))]
        }
        let startup = Analyzer.startupVolume(s)
        let system: JSON = .object(dropping: [
            ("cpu", ["total_percent": F.m(s.cpu.total), "user_percent": F.m(s.cpu.user), "system_percent": F.m(s.cpu.system),
                     "cores": .int(s.cpu.cores.count), "load_average": .array(s.cpu.loadAverage.map(F.r2))]),
            ("memory", mem.isMeasured
                ? ["used": F.bytes(Double(mem.used)), "total": F.bytes(Double(mem.total)), "pressure_percent": F.m(mem.pressure),
                   "swap_used": F.m(mem.swapUsed, F.bytes), "compressed": F.bytes(Double(mem.compressed))]
                : F.unavailable("VM statistics couldn't be read")),
            ("disk", ["read": F.m(s.disk.readBps, F.rate), "write": F.m(s.disk.writeBps, F.rate),
                      "startup_disk_free": startup.map { .str(Fmt.storage($0.available)) }, "startup_disk_size": startup.map { .str(Fmt.storage($0.capacity)) }]),
            ("network", ["in": F.m(s.network.inBps, F.rate), "out": F.m(s.network.outBps, F.rate)]),
            ("power", .object(dropping: power)),
            ("thermal", ["state": F.thermal(s.power.thermalState), "hottest_c": F.m(s.power.hottest),
                         "fans_rpm": s.power.fans.flatMap { $0.isEmpty ? nil : .array($0.map { F.r1($0.rpm) }) }]),
            ("gpu_percent", F.m(s.gpu)),
        ])
        let apps = AppUsage.aggregate(s.processes)
        let byPID = Dictionary(s.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func app(_ a: AppUsage) -> JSON {
            let main = a.pids.compactMap { byPID[$0] }.max { $0.cpu < $1.cpu }
            return ["app": .str(a.name), "cpu_percent": F.r1(a.cpu), "memory": F.bytes(Double(a.memory)),
                    "energy_w": a.energyWatts.map(F.r1), "processes": .int(a.processes), "main_pid": main.map { .int(Int($0.pid)) }]
        }
        let energy = apps.filter { $0.energyWatts != nil }.sorted { $0.energyWatts! > $1.energyWatts! }.prefix(5)
        let top: JSON = [
            "by_cpu": .array(apps.sorted { $0.cpu > $1.cpu }.prefix(5).map(app)),
            "by_memory": .array(apps.sorted { $0.memory > $1.memory }.prefix(5).map(app)),
            "by_energy": energy.isEmpty ? F.unavailable("no app reports energy") : .array(energy.map(app)),
        ]
        let stress = Stress.report(s, limit: 5)
        let hubs: JSON = .object(stress.hubs.map { h in
            (h.subsystem.rawValue, h.stress.map { ["stress": F.r2($0), "reading": .str(h.reading)] } ?? F.unavailable("not measured"))
        })
        let causes: [JSON] = stress.apps.map { m in
            ["app": .str(m.app.name), "misery": F.r2(m.total), "mainly": m.main.map { .str($0.rawValue) }, "hung": m.hung ? true : nil,
             "by_subsystem": .object(m.contributions.filter { $0.value >= 0.01 }.sorted { $0.value > $1.value }.map { ($0.key.rawValue, F.r2($0.value)) }),
             "pid": m.busiest.map { .int(Int($0.pid)) }]
        }
        return object([
            ("time", F.time(s.time)), ("summary", .str(summary)),
            ("findings", .array(findings.prefix(15).map { Self.finding($0, tabs: tabs) })),
            ("system", system), ("top_apps", top),
            ("stress_map", ["about": "Stress 0-1 per subsystem; misery = an app's share of a resource x how strained it is (top causes of the Mac's misery).",
                            "subsystems": hubs, "top_causes": causes.isEmpty ? "none: nothing is strained" : .array(causes)]),
        ])
    }

    // MARK: list_processes

    func listProcesses(_ a: Args) async throws -> JSON {
        let sort = try a.choice("sort", Self.processSorts, default: "cpu")
        let limit = try a.int("limit", default: 20, 1...100)
        let filter = try a.string("filter") ?? ""
        let byApp = try a.bool("by_app")
        guard let s = await source.snapshot() else { throw noSample() }
        let helper = await source.helperAccess()
        let q = ProcessQuery(filter)
        let procs = s.processes.filter(q.matches)
        // Larger first; nil (unmeasured) always last, whatever the direction.
        func desc(_ x: Double?, _ y: Double?) -> Bool { (x ?? -.infinity) > (y ?? -.infinity) }
        if byApp {
            let apps = AppUsage.aggregate(procs).sorted { x, y in
                switch sort {
                case "memory": return x.memory > y.memory
                case "energy": return desc(x.energyWatts, y.energyWatts)
                case "gpu": return desc(x.gpu, y.gpu)
                case "disk": return x.diskBps > y.diskBps
                case "network": return x.netBps > y.netBps
                case "wakeups": return x.wakeups > y.wakeups
                case "threads": return x.threads > y.threads
                case "name": return x.name.localizedCaseInsensitiveCompare(y.name) == .orderedAscending
                case "pid": return (x.pids.min() ?? 0) < (y.pids.min() ?? 0)
                default: return x.cpu > y.cpu
                }
            }
            let rows: [JSON] = apps.prefix(limit).map { x in
                [.str(x.name), .int(x.processes), F.r1(x.cpu), F.bytes(Double(x.memory)), x.energyWatts.map(F.r1) ?? .null,
                 x.gpu.map(F.r1) ?? .null, F.rate(x.diskBps), F.rate(x.netBps), F.r1(x.wakeups), .array(x.pids.prefix(5).map { .int(Int($0)) })]
            }
            return object([("time", F.time(s.time)), ("apps", .int(apps.count)), ("shown", .int(rows.count)), ("sort", .str(sort)),
                           ("columns", ["app", "processes", "cpu_percent", "memory", "energy_w", "gpu_percent", "disk", "network", "wakeups_per_s", "pids"]),
                           ("rows", .array(rows))] + helperPairs(helper))
        }
        let sorted = procs.sorted { x, y in
            switch sort {
            case "memory": return desc(Self.memory(x), Self.memory(y))
            case "energy": return desc(x.energyWatts, y.energyWatts)
            case "gpu": return desc(x.gpu, y.gpu)
            case "disk": return x.diskReadBps + x.diskWriteBps > y.diskReadBps + y.diskWriteBps
            case "network": return desc(x.network.map { $0.inBps + $0.outBps }, y.network.map { $0.inBps + $0.outBps })
            case "wakeups": return x.wakeups > y.wakeups
            case "threads": return x.threads > y.threads
            case "name": return x.name.localizedCaseInsensitiveCompare(y.name) == .orderedAscending
            case "pid": return x.pid < y.pid
            default: return desc(Self.cpu(x), Self.cpu(y))
            }
        }
        let rows: [JSON] = sorted.prefix(limit).map { p in
            var flags: [String] = []
            if p.notResponding == true { flags.append("not responding") }
            if p.powerAssertions != nil { flags.append("keeps Mac awake") }
            if p.translated == true { flags.append("Intel (Rosetta)") }
            if p.restricted { flags.append(p.source == .helper ? "via helper" : "restricted") }
            return [.int(Int(p.pid)), .str(p.name), .str(p.user), Self.cpu(p).map(F.r1) ?? .null, Self.memory(p).map(F.bytes) ?? .null,
                    p.energyWatts.map(F.r1) ?? .null, p.gpu.map(F.r1) ?? .null, Self.unreadable(p) ? .null : F.rate(p.diskReadBps + p.diskWriteBps),
                    p.network.map { F.rate($0.inBps + $0.outBps) } ?? .null, Self.unreadable(p) ? .null : F.r1(p.wakeups),
                    Self.unreadable(p) ? .null : .int(p.threads),
                    flags.isEmpty ? .null : .strings(flags)]
        }
        // Chrome tabs (MCPChromeTabsOutput.swift): a last column of hosts when available, else one top-level note.
        let tabs = await source.chromeTabs()
        let tabRows: [JSON] = tabs.map { t in zip(sorted.prefix(limit), rows).map { p, r in .array((r.array ?? []) + [t.hostsCell(pid: p.pid)]) } } ?? rows
        return object([("time", F.time(s.time)), ("processes", .int(s.processes.count)), ("matched", .int(procs.count)),
                       ("shown", .int(rows.count)), ("sort", .str(sort)),
                       ("columns", .strings(["pid", "name", "user", "cpu_percent", "memory", "energy_w", "gpu_percent", "disk", "network", "wakeups_per_s", "threads", "flags"] + (tabs == nil ? [] : ["chrome_tabs"]))),
                       ("rows", .array(tabRows)), ("chrome_tabs", tabs == nil ? ChromeTabsView.unavailable : nil)] + helperPairs(helper))
    }

    // MARK: get_process

    /// What the catalog says about a process. A lookalike is reported exactly like an unknown process. Catalog text
    /// isn't process contents, so it isn't behind the MCP contents setting.
    static func aboutJSON(_ m: ProcessMatch) -> JSON {
        guard case .known(let e, let key, let verified) = m else { return ["known": false] }
        return .object([("known", .bool(true)), ("title", .str(e.title)), ("summary", .str(e.summary)), ("maker", .str(e.makerName)),
                        ("maker_is_apple", .bool(e.isApple)), ("managed", .bool(e.managed)), ("busy_when", e.busyWhen.map(JSON.str) ?? .null),
                        ("quit", .str(e.quit.rawValue)), ("what_to_do", e.whatToDo.map(JSON.str) ?? .null),
                        ("matched_by", .str(key.rawValue)), ("path_verified", .bool(verified))])
    }

    func getProcess(_ a: Args) async throws -> JSON {
        let pid = Int32(clamping: try a.requiredInt("pid"))
        let include = Set(try a.choices("include", Self.processSections))
        guard let s = await source.snapshot() else { throw noSample() }
        guard let p = s.processes.first(where: { $0.pid == pid }) else {
            throw ArgError(message: "No process with PID \(pid) in the latest sample (it may have exited). Use list_processes to find one.")
        }
        let inspect = inspector
        // Signature checks and the fd scan are slow-ish blocking calls; keep them off the caller's executor.
        let d = await Task.detached(priority: .userInitiated) { inspect(pid, p.path) }.value
        let helper = await source.helperAccess()
        func measured<T>(_ m: Measured<T>, _ f: (T) -> JSON) -> JSON {
            switch m { case .value(let v): return f(v); case .unavailable(let r): return F.unavailable(r) }
        }
        let listening = d.sockets.filter { $0.state == "LISTEN" }.map { "\($0.proto) \($0.local)" }
        let sig: JSON? = d.signature.map { g in
            ["summary": .str(g.summary), "identifier": g.identifier.map(JSON.str), "team": g.teamID.map(JSON.str),
             "apple": .bool(g.isApple), "valid": .bool(g.valid), "hardened_runtime": .bool(g.hardenedRuntime)]
        }
        var pairs: [(String, JSON?)] = [
            ("pid", .int(Int(pid))), ("name", .str(p.name)), ("app", .str(AppUsage.key(for: p).name)),
            ("path", p.path.isEmpty ? F.unavailable("not readable") : .str(p.path)),
            ("user", .str(p.user)), ("uid", .int(Int(p.uid))), ("started", F.time(p.startDate)),
            ("ancestry", d.ancestry.isEmpty ? F.unavailable("not readable") : .str(d.ancestry.map { "\($0.name)(\($0.pid))" }.joined(separator: " < "))),
            ("cpu_percent", Self.cpu(p).map(F.r1) ?? F.unavailable("not permitted")),
            ("cpu_time_s", Self.cpu(p) == nil ? nil : F.r1(p.cpuTime)),
            ("memory", Self.memory(p).map(F.bytes) ?? F.unavailable("not permitted")),
            ("peak_memory", d.counters?.peakFootprint.map { F.bytes(Double($0)) }),
            ("threads", Self.unreadable(p) ? F.unavailable("not permitted") : .int(p.threads)),
            ("energy_w", p.energyWatts.map(F.r1) ?? F.unavailable("not reported")),
            ("gpu_percent", p.gpu.map(F.r1)), ("wakeups_per_s", Self.unreadable(p) ? F.unavailable("not permitted") : F.r1(p.wakeups)),
            ("disk", Self.unreadable(p) ? F.unavailable("not permitted")
                : ["read": F.rate(p.diskReadBps), "write": F.rate(p.diskWriteBps), "total_written": F.bytes(Double(p.diskWritten))]),
            ("network", p.network.map { ["in": F.rate($0.inBps), "out": F.rate($0.outBps), "connections": .int($0.connections)] } ?? F.unavailable("not measured")),
            ("not_responding", p.notResponding.map(JSON.bool)),
            ("architecture", p.translated.map { $0 ? "Intel (Rosetta)" : "native" }),
            ("keeps_mac_awake", p.powerAssertions.map { .strings($0.map { "\($0.type): \($0.name)" }) }),
            ("nice", d.nice.map { .int(Int($0)) }),
            ("open_files", measured(d.files) { .int($0.count) }),
            ("sockets", d.files.isAvailable ? .int(d.sockets.count) : nil),
            ("listening_ports", d.files.isAvailable ? .strings(listening) : nil),
            ("cwd", measured(d.cwd, JSON.str)),
            ("code_signature", sig ?? F.unavailable("executable not readable")),
            ("about", Self.aboutJSON(catalog.lookup(name: p.name, path: p.path, signature: d.signature))),
            ("chrome_tabs", await source.chromeTabs()?.json(pid: pid)),   // hosts only, for a Chrome renderer
        ]
        if include.contains("arguments") {
            pairs.append(("arguments", measured(d.arguments) { .strings($0.prefix(64).map { String($0.prefix(500)) }) }))
        }
        if include.contains("files") {
            pairs.append(("files", measured(d.files) { .array($0.prefix(100).map { f in .str("\(f.fd) \(f.kind.rawValue): \(f.description)") }) }))
        }
        if include.contains("sockets") {
            pairs.append(("socket_list", .array(d.sockets.prefix(100).map { k in .str("\(k.proto) \(k.local) -> \(k.remote) \(k.state)") })))
        }
        if include.contains("threads") {
            pairs.append(("thread_list", measured(d.threads) { ts in
                .array(ts.sorted { $0.cpu > $1.cpu }.prefix(30).map { t in
                    ["id": .int(Int(clamping: t.id)), "name": t.name.isEmpty ? nil : .str(t.name), "cpu_percent": F.r1(t.cpu), "state": .str(t.state)]
                })
            }))
        }
        if p.uid != ownUID { await applyHelperContents(&pairs, p, include: include, access: helper) }
        if p.source == .helper { pairs.append(("counters_from", .str("helper"))) }   // "source" is the data source line
        return object(pairs + helperPairs(helper))
    }

    // MARK: sample_stacks

    func sampleStacks(_ a: Args) async throws -> JSON {
        let pid = Int32(clamping: try a.requiredInt("pid"))
        let seconds = try a.int("seconds", default: 3, 1...5)
        guard let s = await source.snapshot() else { throw noSample() }
        guard let p = s.processes.first(where: { $0.pid == pid }) else {
            throw ArgError(message: "No process with PID \(pid) in the latest sample (it may have exited).")
        }
        // Without root, `sample` can only attach to the user's own processes; refusing up front gives a clear answer
        // and keeps this tool from probing anything else.
        let helper = await source.helperAccess()
        let report: String
        if p.uid == ownUID {
            let sampler = stackSampler
            report = await Task.detached(priority: .userInitiated) { sampler(pid, seconds) }.value
        } else {
            // Another user's or a root process: only through the helper, only with agent access to contents on, and
            // only because this call asked for it (never automatically).
            let refused = "PID \(pid) (\(p.name)) belongs to \(p.user); only your own processes can be sampled"
            guard helper.contentsAllowed else {
                throw ArgError(message: "\(refused) (\(helper.state == .unlocked ? Self.contentsOffNote : Self.unlockNote)).")
            }
            switch await source.helperSample(p.identity, seconds: seconds) {
            case .success(let r)?: report = r
            case .failure(let r)?: throw ArgError(message: r.message)
            case nil: throw ArgError(message: "\(refused) (\(Self.unlockNote)).")
            }
        }
        guard report.contains("Call graph") || report.contains("Thread_") else { throw ArgError(message: String(report.prefix(500))) }
        return object([("pid", .int(Int(pid))), ("name", .str(p.name)), ("seconds", .int(seconds)),
                       ("summary", .str(StackSummary.summarize(report) ?? "No main-thread call graph found in the sample.")),
                       ("main_thread", .strings(Self.mainThreadLines(report)))] + helperPairs(helper))
    }

    /// get_process on another user's process: arguments, working folder and open files come from the helper only
    /// with agent access to contents on; unlocked with it off, they say how to turn it on; otherwise today's values.
    func applyHelperContents(_ pairs: inout [(String, JSON?)], _ p: ProcessSample, include: Set<String>, access: HelperMCPAccess) async {
        func set(_ key: String, _ v: JSON?) {
            if let i = pairs.firstIndex(where: { $0.0 == key }) { pairs[i].1 = v } else { pairs.append((key, v)) }
        }
        guard access.state == .unlocked else { return }
        var keys = ["cwd", "open_files"]
        if include.contains("arguments") { keys.append("arguments") }
        if include.contains("files") { keys.append("files") }
        guard access.agentContents else {
            for k in keys { set(k, F.unavailable(Self.contentsOffNote)) }
            return
        }
        var parts: Set<DetailPart> = [.cwd, .files]
        if include.contains("arguments") { parts.insert(.args) }
        guard let c = await source.helperContents(p.identity, parts: parts) else { return }
        if let cwd = c.cwd { set("cwd", .str(cwd)) }
        if let files = c.files {
            set("open_files", .int(files.count))
            if include.contains("files") { set("files", .array(files.prefix(100).map { .str($0) })) }
        }
        if include.contains("arguments"), let args = c.args { set("arguments", .strings(args.prefix(64).map { String($0.prefix(500)) })) }
    }

    /// The first lines of the main thread's call graph from `sample` output (its heaviest path comes first), trimmed
    /// of addresses so the tree stays readable in few tokens.
    static func mainThreadLines(_ report: String, max: Int = 40) -> [String] {
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.contains("Thread_") && ($0.contains("Main Thread") || $0.contains("com.apple.main-thread")) })
                ?? lines.firstIndex(where: { $0.contains("Thread_") }) else { return [] }
        var out: [String] = [String(lines[start].trimmingCharacters(in: .whitespaces))]
        for l in lines[(start + 1)...] {
            if l.contains("Thread_") || l.hasPrefix("Total number in stack") || l.trimmingCharacters(in: .whitespaces).isEmpty || out.count >= max { break }
            var t = String(l)
            if let r = t.range(of: "  [0x") { t = String(t[..<r.lowerBound]) }   // drop "[0x1234,0x5678]" address lists
            out.append(String(t.prefix(200)))
        }
        return out
    }
}
