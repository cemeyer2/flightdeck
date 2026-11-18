import Foundation

// Live developer activity derived from the process sample the app already takes every tick (so it costs no extra
// sampling): which builds are running and how much CPU they use, what the container engine's own processes cost, and
// how busy each booted iOS/watchOS/visionOS simulator is. Plus the booted-simulator list from `simctl`.

/// The running processes of one build tool, summed ("Swift compiler × 12 · 640% CPU · 1:42").
public struct BuildActivity: Identifiable, Hashable, Sendable {
    public var id: String { tool }
    public var tool: String
    public var processes: Int
    public var cpu: Double            // % of one core, summed
    public var memory: UInt64
    /// Start of the oldest process in the group.
    public var since: Date
    public init(tool: String, processes: Int, cpu: Double, memory: UInt64, since: Date) {
        self.tool = tool; self.processes = processes; self.cpu = cpu; self.memory = memory; self.since = since
    }
}

/// A container engine's own processes (the VM, its helpers), summed.
public struct EngineUsage: Identifiable, Hashable, Sendable {
    public var id: String { engine }
    public var engine: String
    public var processes: Int
    public var cpu: Double
    public var memory: UInt64
    public init(engine: String, processes: Int, cpu: Double, memory: UInt64) {
        self.engine = engine; self.processes = processes; self.cpu = cpu; self.memory = memory
    }
}

/// One booted simulator from `xcrun simctl list devices booted -j`.
public struct Simulator: Identifiable, Hashable, Sendable {
    public var id: String { udid }
    public var udid: String
    public var name: String
    /// Human runtime ("iOS 18.2") derived from the runtime identifier.
    public var runtime: String
    public init(udid: String, name: String, runtime: String) { self.udid = udid; self.name = name; self.runtime = runtime }
}

public enum SimulatorStatus: Sendable {
    case noXcode(String)
    case failed(String)
    case ok([Simulator])
}

public enum DevActivity {
    /// Groups the sample's build processes by tool. `args` returns a process's command line (own processes only) and
    /// is consulted just for the interpreted tools DevClassifier can't name from the process name alone.
    public static func builds(_ procs: [ProcessSample], args: (ProcessSample) -> [String]?) -> [BuildActivity] {
        var groups: [String: BuildActivity] = [:]
        for p in procs {
            let a = DevClassifier.needsArguments(p.name) ? args(p) : nil
            guard let tool = DevClassifier.build(name: p.name, args: a) else { continue }
            var g = groups[tool] ?? BuildActivity(tool: tool, processes: 0, cpu: 0, memory: 0, since: p.startDate)
            g.processes += 1; g.cpu += p.cpu; g.memory += p.memory; g.since = min(g.since, p.startDate)
            groups[tool] = g
        }
        return groups.values.sorted { ($0.cpu, $0.tool) > ($1.cpu, $1.tool) }
    }

    /// Names the container engine a process belongs to, from its path, or nil. Virtualization.framework VMs are
    /// listed apart: Docker Desktop, OrbStack, Colima (vz) and UTM all run their Linux VM in Apple's
    /// `com.apple.Virtualization.VirtualMachine` XPC service, which can't be attributed to an app without private API.
    public static func engine(name: String, path: String) -> String? {
        if path.contains("/Docker.app/") || name.hasPrefix("com.docker.") { return "Docker Desktop" }
        if path.contains("/OrbStack.app/") || name.hasPrefix("OrbStack") { return "OrbStack" }
        if path.contains("/Rancher Desktop.app/") { return "Rancher Desktop" }
        if name == "limactl" || name == "colima" || path.contains("/lima/") { return "Colima / Lima" }
        if name.hasPrefix("qemu-system") { return "QEMU VM" }
        if name == "com.apple.Virtualization.VirtualMachine" || path.contains("Virtualization.framework") && name.contains("VirtualMachine") {
            return "Virtualization.framework VM (owner not identifiable)"
        }
        return nil
    }

    public static func engines(_ procs: [ProcessSample]) -> [EngineUsage] {
        var groups: [String: EngineUsage] = [:]
        for p in procs {
            guard let e = engine(name: p.name, path: p.path) else { continue }
            var g = groups[e] ?? EngineUsage(engine: e, processes: 0, cpu: 0, memory: 0)
            g.processes += 1; g.cpu += p.cpu; g.memory += p.memory
            groups[e] = g
        }
        return groups.values.sorted { $0.engine < $1.engine }
    }

    /// CPU and memory of each booted simulator: every process descended from that device's `launchd_sim`, which is
    /// recognised by the device UDID in its command line (the simulator's data directory path). nil for a device
    /// whose launchd_sim isn't found (still booting, or its command line unreadable).
    public static func simulatorUsage(_ sims: [Simulator], procs: [ProcessSample], args: (ProcessSample) -> [String]?) -> [String: (cpu: Double, memory: UInt64, processes: Int)] {
        var roots: [Int32: String] = [:]
        for p in procs where p.name == "launchd_sim" {
            let line = (args(p) ?? []).joined(separator: " ")
            if let s = sims.first(where: { line.contains($0.udid) }) { roots[p.pid] = s.udid }
        }
        guard !roots.isEmpty else { return [:] }
        let byPID = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: (cpu: Double, memory: UInt64, processes: Int)] = [:]
        for p in procs {
            // Walk up the parent chain (bounded, in case of a cycle in a racy sample) until a launchd_sim root is hit.
            var cur: ProcessSample? = p, hops = 0
            while let c = cur, hops < 64 {
                if let udid = roots[c.pid] {
                    var u = out[udid] ?? (0, 0, 0)
                    u.cpu += p.cpu; u.memory += p.memory; u.processes += 1
                    out[udid] = u; break
                }
                cur = c.ppid > 1 ? byPID[c.ppid] : nil; hops += 1
            }
        }
        return out
    }

    /// Lists booted simulators. Runs `xcrun simctl` only with a full Xcode selected (simctl isn't part of the
    /// Command Line Tools, and the xcrun stub would otherwise offer to install them). Blocking; off the main thread.
    public static func bootedSimulators() -> SimulatorStatus {
        guard let dev = Toolchains.developerDirectory() else { return .noXcode("no developer directory selected") }
        if dev.hasSuffix("/CommandLineTools") { return .noXcode("simulators need Xcode; only the Command Line Tools are selected") }
        guard let r = DevShell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"], timeout: 15) else { return .failed("xcrun couldn't be started") }
        guard r.ok else { return .failed(r.reason) }
        return parseSimctl(r.stdout).map { .ok($0) } ?? .failed("simctl printed unexpected output")
    }

    /// Parses simctl's JSON: {"devices": {"<runtime id>": [{"udid", "name", "state", …}]}}. Only "Booted" devices are kept
    /// (the `booted` filter already does this, but older simctl versions ignore it with -j).
    static func parseSimctl(_ out: String) -> [Simulator]? {
        guard let start = out.firstIndex(of: "{"),
              let root = (try? JSONSerialization.jsonObject(with: Data(out[start...].utf8))) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else { return nil }
        var sims: [Simulator] = []
        for (runtime, list) in devices {
            for d in (list as? [[String: Any]]) ?? [] where (d["state"] as? String) == "Booted" {
                guard let udid = d["udid"] as? String else { continue }
                sims.append(Simulator(udid: udid, name: d["name"] as? String ?? "Simulator", runtime: runtimeName(runtime)))
            }
        }
        return sims.sorted { ($0.runtime, $0.name) < ($1.runtime, $1.name) }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-2" → "iOS 18.2"; older simctl used the plain "iOS 12.4" key.
    static func runtimeName(_ id: String) -> String {
        guard let r = id.range(of: "SimRuntime.") else { return id }
        let parts = id[r.upperBound...].split(separator: "-")
        guard let os = parts.first else { return id }
        return parts.count > 1 ? "\(os) " + parts.dropFirst().joined(separator: ".") : String(os)
    }
}
