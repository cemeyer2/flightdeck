import Foundation

// Containers for the Developer destination, through whichever docker CLI is installed (Docker Desktop, OrbStack,
// Colima and Rancher Desktop all ship or work with one). Reads `docker ps -a` and `docker stats --no-stream`, both in
// their one-JSON-object-per-line format, and runs start/stop/restart on request. Nothing here runs on a timer: the
// UI calls `DockerCLI.status()` only while its view is visible.

/// One container from `docker ps -a --format '{{json .}}'`. Fields are strings as Docker prints them.
public struct DockerContainer: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var image: String
    /// "running", "exited", "paused", "created", "restarting", "removing" or "dead".
    public var state: String
    /// Human status ("Up 2 hours", "Exited (0) 3 days ago").
    public var status: String
    /// Published ports as printed ("0.0.0.0:8080->80/tcp, :::8080->80/tcp").
    public var ports: String
    public var composeProject: String?
    public var isRunning: Bool { state == "running" || state == "restarting" }
    public init(id: String, name: String, image: String, state: String, status: String, ports: String, composeProject: String? = nil) {
        self.id = id; self.name = name; self.image = image; self.state = state; self.status = status; self.ports = ports
        self.composeProject = composeProject
    }

    /// Host ports this container publishes, from `ports` ("0.0.0.0:8080->80/tcp" publishes 8080; "80/tcp" alone
    /// is exposed but not published). Ranges ("0.0.0.0:8000-8002->8000-8002/tcp") expand to each port.
    public var publishedPorts: [Int] {
        var out = Set<Int>()
        for part in ports.split(separator: ",") {
            guard let arrow = part.range(of: "->") else { continue }
            let host = part[..<arrow.lowerBound]
            guard let colon = host.lastIndex(of: ":") else { continue }
            let spec = host[host.index(after: colon)...]
            let bounds = spec.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 1 { out.insert(bounds[0]) }
            else if bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] < 1000 { out.formUnion(bounds[0]...bounds[1]) }
        }
        return out.sorted()
    }
}

/// One container's resource use from `docker stats --no-stream`. CPU is % of one core (Docker's convention, so 200%
/// = two cores); memory and I/O stay as Docker formats them, plus parsed byte counts where the text parses.
public struct DockerStats: Hashable, Sendable {
    public var id: String
    public var name: String
    public var cpu: Double?
    public var memoryUsage: String
    public var memoryBytes: Double?
    public var memoryPercent: Double?
    public var netIO: String
    public var blockIO: String
    public var pids: Int?
    public init(id: String, name: String, cpu: Double?, memoryUsage: String, memoryBytes: Double?, memoryPercent: Double?,
                netIO: String, blockIO: String, pids: Int?) {
        self.id = id; self.name = name; self.cpu = cpu; self.memoryUsage = memoryUsage; self.memoryBytes = memoryBytes
        self.memoryPercent = memoryPercent; self.netIO = netIO; self.blockIO = blockIO; self.pids = pids
    }
}

/// What the Containers panel shows.
public enum DockerStatus: Sendable {
    /// No docker CLI in any of the usual places.
    case noCLI
    /// The CLI exists but the engine didn't answer (not running, or a broken context). `reason` is Docker's own message.
    case unreachable(cli: String, reason: String)
    /// `stats` is keyed by container ID prefix; it is empty when nothing runs, and `statsError` says when it failed.
    case ok(cli: String, containers: [DockerContainer], stats: [String: DockerStats], statsError: String?)
}

public enum DockerCLI {
    /// The docker CLI to use, or nil. Only checks the file system.
    public static func locate() -> String? { DevShell.find("docker") }

    /// Lists containers and, when any are running, their stats. Blocking: `docker ps` takes ~0.1 s, and
    /// `docker stats --no-stream` ~1-2 s because it waits for two CPU readings. Call off the main thread.
    public static func status() -> DockerStatus {
        guard let cli = locate() else { return .noCLI }
        guard let ps = DevShell.run(cli, ["ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeout: 10) else {
            return .unreachable(cli: cli, reason: "the docker CLI couldn't be started")
        }
        guard ps.ok else { return .unreachable(cli: cli, reason: ps.reason) }
        let containers = parsePS(ps.stdout)
        guard containers.contains(where: \.isRunning) else { return .ok(cli: cli, containers: containers, stats: [:], statsError: nil) }
        let st = DevShell.run(cli, ["stats", "--no-stream", "--no-trunc", "--format", "{{json .}}"], timeout: 15)
        let stats = Dictionary(parseStats(st?.stdout ?? "").map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return .ok(cli: cli, containers: containers, stats: stats, statsError: st.map { $0.ok ? nil : $0.reason } ?? "docker stats couldn't be started")
    }

    public enum Action: String, Sendable, CaseIterable { case start, stop, restart }

    /// Runs `docker start|stop|restart <id>` and returns nil on success or the error text. The full container ID is
    /// passed, never a name, so a container recreated under the same name in the meantime isn't touched by mistake.
    public static func perform(_ a: Action, containerID: String) -> String? {
        guard let cli = locate() else { return "the docker CLI is no longer installed" }
        guard let r = DevShell.run(cli, [a.rawValue, containerID], timeout: 60) else { return "the docker CLI couldn't be started" }
        return r.ok ? nil : r.reason
    }

    /// Parses `docker ps --format '{{json .}}'`: one object per line, keys as in Docker's Go template (ID, Names,
    /// Image, State, Status, Ports, Labels). Lines that aren't JSON objects (warnings) are skipped. Older engines
    /// don't print State, so it is then derived from Status ("Up …" means running).
    static func parsePS(_ out: String) -> [DockerContainer] {
        jsonLines(out).compactMap { o in
            guard let id = o["ID"] as? String, !id.isEmpty else { return nil }
            let status = o["Status"] as? String ?? ""
            let state = (o["State"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
                ?? (status.hasPrefix("Up") ? "running" : status.hasPrefix("Exited") ? "exited" : status.lowercased())
            let labels = o["Labels"] as? String ?? ""
            // Labels is one comma-separated "key=value" string; Compose marks its containers with this label.
            let project = labels.split(separator: ",").first { $0.hasPrefix("com.docker.compose.project=") }
                .map { String($0.dropFirst("com.docker.compose.project=".count)) }
            return DockerContainer(id: id, name: o["Names"] as? String ?? "", image: o["Image"] as? String ?? "",
                                   state: state, status: status, ports: o["Ports"] as? String ?? "", composeProject: project)
        }
    }

    /// Parses `docker stats --no-stream --format '{{json .}}'` lines ("CPUPerc":"12.34%","MemUsage":"7.5MiB / 7.66GiB").
    /// Values Docker prints as "--" (a container that just stopped) stay nil.
    static func parseStats(_ out: String) -> [DockerStats] {
        jsonLines(out).compactMap { o in
            guard let id = (o["ID"] as? String) ?? (o["Container"] as? String), !id.isEmpty else { return nil }
            let mem = o["MemUsage"] as? String ?? ""
            return DockerStats(id: id, name: o["Name"] as? String ?? "", cpu: percent(o["CPUPerc"] as? String),
                               memoryUsage: mem, memoryBytes: bytes(mem.components(separatedBy: " / ").first ?? ""),
                               memoryPercent: percent(o["MemPerc"] as? String), netIO: o["NetIO"] as? String ?? "",
                               blockIO: o["BlockIO"] as? String ?? "", pids: (o["PIDs"] as? String).flatMap { Int($0) })
        }
    }

    /// The stats entry for a container: `docker stats` IDs may be shortened, so a prefix match is accepted.
    public static func stats(for c: DockerContainer, in s: [String: DockerStats]) -> DockerStats? {
        s[c.id] ?? s.first { c.id.hasPrefix($0.key) || $0.key.hasPrefix(c.id) }?.value
    }

    static func jsonLines(_ out: String) -> [[String: Any]] {
        out.split(separator: "\n").compactMap { line in
            guard line.first == "{" else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    /// "12.34%" → 12.34; "--" or garbage → nil.
    static func percent(_ s: String?) -> Double? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), s.hasSuffix("%") else { return nil }
        return Double(s.dropLast())
    }

    /// Docker's sizes: binary units with an "i" ("7.5MiB") for memory, decimal ("1.2kB", "3MB") for I/O.
    static func bytes(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let split = t.firstIndex(where: { $0.isLetter }), let n = Double(t[..<split]) else { return nil }
        let units: [String: Double] = ["B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
                                       "KiB": 1024, "MiB": 1_048_576, "GiB": 1_073_741_824, "TiB": 1_099_511_627_776]
        return units[String(t[split...])].map { n * $0 }
    }
}
