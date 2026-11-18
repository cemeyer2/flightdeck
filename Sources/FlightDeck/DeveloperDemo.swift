import Foundation
import FlightDeckCore

// Demo mode for the Developer destination: an invented developer's afternoon (a Vite front end, a FastAPI back end,
// Rails, Postgres and Ollama; a Compose project in Docker; a few Homebrew services; an Xcode build and a booted
// simulator). Nothing comes from this Mac, and the model refuses every action in demo mode.
// PIDs and start times are invented, so `AppActions.openInspector` (nil in demo mode) can never open a real process.

@MainActor
enum DeveloperDemo {
    static func fill(_ m: DeveloperModel) {
        let now = Date().timeIntervalSince1970
        func id(_ pid: Int32, minutesAgo: Double) -> ProcessIdentity { ProcessIdentity(pid: pid, startTime: UInt64((now - minutesAgo * 60) * 1e6)) }
        let home = "/Users/demo/Projects"
        let servers: [(DevServer, Double, Double)] = [
            (DevServer(identity: id(4811, minutesAgo: 95), kind: .init("Vite", .javascript), process: "node", executable: "/opt/homebrew/bin/node",
                       arguments: ["node", "\(home)/storefront/node_modules/.bin/vite"], ports: [5173], address: "::1",
                       projectFolder: .value("\(home)/storefront")), 3.2, 0.21),
            (DevServer(identity: id(4902, minutesAgo: 88), kind: .init("uvicorn", .python), process: "python3.12", executable: "/opt/homebrew/bin/python3.12",
                       arguments: ["python3.12", "\(home)/storefront-api/.venv/bin/uvicorn", "app.main:app", "--reload"], ports: [8000], address: "127.0.0.1",
                       projectFolder: .value("\(home)/storefront-api")), 0.8, 0.09),
            (DevServer(identity: id(3377, minutesAgo: 240), kind: .init("Puma", .ruby), process: "ruby", executable: "/Users/demo/.rbenv/versions/3.3.5/bin/ruby",
                       arguments: ["puma 6.4.3 (tcp://0.0.0.0:3000) [ledger]"], ports: [3000], address: "*",
                       projectFolder: .value("\(home)/ledger")), 0.3, 0.32),
            (DevServer(identity: id(611, minutesAgo: 2900), kind: .init("PostgreSQL", .database), process: "postgres", executable: "/opt/homebrew/opt/postgresql@16/bin/postgres",
                       arguments: ["postgres", "-D", "/opt/homebrew/var/postgresql@16"], ports: [5432], address: "127.0.0.1",
                       projectFolder: .value("/opt/homebrew/var/postgresql@16")), 0.4, 0.06),
            (DevServer(identity: id(702, minutesAgo: 2900), kind: .init("Ollama", .ai), process: "ollama", executable: "/Applications/Ollama.app/Contents/Resources/ollama",
                       arguments: ["ollama", "serve"], ports: [11434], address: "127.0.0.1",
                       projectFolder: .unavailable("not permitted")), 46, 5.4),
            (DevServer(identity: id(5120, minutesAgo: 30), kind: .init("Docker port forward", .container), process: "com.docker.backend",
                       executable: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", arguments: ["com.docker.backend"], ports: [8080, 6379],
                       address: "*", projectFolder: .value("/")), 1.1, 0.14),
        ]
        let gb = 1_073_741_824.0
        m.servers = DevServerScan(servers: servers.map(\.0), otherOwnListeners: ["Spotify", "rapportd"], coverage: .allProcesses)
        for (s, cpu, mem) in servers { m.demoUsage[s.identity] = (cpu, UInt64(mem * gb)) }

        let containers = [
            DockerContainer(id: "3f1c2a9b7d10e8", name: "storefront-web-1", image: "nginx:1.27", state: "running", status: "Up 31 minutes",
                            ports: "0.0.0.0:8080->80/tcp", composeProject: "storefront"),
            DockerContainer(id: "8a7b6c5d4e3f21", name: "storefront-redis-1", image: "redis:7.4", state: "running", status: "Up 31 minutes",
                            ports: "0.0.0.0:6379->6379/tcp", composeProject: "storefront"),
            DockerContainer(id: "c0ffee123456ab", name: "storefront-worker-1", image: "storefront-worker:dev", state: "running", status: "Up 29 minutes",
                            ports: "", composeProject: "storefront"),
            DockerContainer(id: "9d8e7f6a5b4c3d", name: "minio", image: "minio/minio:latest", state: "exited", status: "Exited (0) 2 days ago", ports: ""),
        ]
        func st(_ c: DockerContainer, _ cpu: Double, _ mem: String, _ memB: Double, _ net: String, _ io: String, _ pids: Int) -> (String, DockerStats) {
            (c.id, DockerStats(id: c.id, name: c.name, cpu: cpu, memoryUsage: mem, memoryBytes: memB, memoryPercent: memB / (7.65 * gb) * 100,
                               netIO: net, blockIO: io, pids: pids))
        }
        m.docker = .ok(cli: "/usr/local/bin/docker", containers: containers, stats: Dictionary(uniqueKeysWithValues: [
            st(containers[0], 0.4, "18.2MiB / 7.65GiB", 18.2 * 1_048_576, "1.4MB / 6.2MB", "0B / 8.2kB", 9),
            st(containers[1], 1.9, "11.6MiB / 7.65GiB", 11.6 * 1_048_576, "820kB / 2.1MB", "4.1MB / 0B", 6),
            st(containers[2], 38.5, "412MiB / 7.65GiB", 412 * 1_048_576, "3.3MB / 900kB", "120MB / 44MB", 23),
        ]), statsError: nil)
        m.demoEngines = [EngineUsage(engine: "Docker Desktop", processes: 7, cpu: 41.2, memory: UInt64(2.6 * gb)),
                         EngineUsage(engine: "Virtualization.framework VM (owner not identifiable)", processes: 1, cpu: 52.0, memory: UInt64(3.1 * gb))]

        m.brew = .ok([
            BrewService(name: "postgresql@16", status: "started", user: "demo", plist: "/Users/demo/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist", exitCode: 0),
            BrewService(name: "redis", status: "none", user: nil, plist: "/opt/homebrew/opt/redis/homebrew.mxcl.redis.plist", exitCode: nil),
            BrewService(name: "nginx", status: "error", user: "demo", plist: "/Users/demo/Library/LaunchAgents/homebrew.mxcl.nginx.plist", exitCode: 78),
            BrewService(name: "unbound", status: "started", user: "root", plist: "/Library/LaunchDaemons/homebrew.mxcl.unbound.plist", exitCode: 0),
        ])

        let started = Date().addingTimeInterval(-102)
        m.demoBuilds = [BuildActivity(tool: "Swift compiler", processes: 10, cpu: 612, memory: UInt64(3.8 * gb), since: started),
                        BuildActivity(tool: "xcodebuild", processes: 1, cpu: 14, memory: UInt64(0.4 * gb), since: started),
                        BuildActivity(tool: "clang", processes: 2, cpu: 96, memory: UInt64(0.3 * gb), since: started.addingTimeInterval(40))]

        m.toolchains = [
            Toolchain(tool: "Xcode (selected)", version: "26.1 (17B55)", path: "/Applications/Xcode.app/Contents/Developer", note: nil),
            Toolchain(tool: "Xcode-beta", version: "26.2", path: "/Applications/Xcode-beta.app", note: "not selected"),
            Toolchain(tool: "Swift", version: "6.2.1", path: "/usr/bin/swift", note: nil),
            Toolchain(tool: "Node.js", version: "22.11.0", path: "/opt/homebrew/bin/node", note: nil),
            Toolchain(tool: "Python", version: "3.12.7", path: "/opt/homebrew/bin/python3", note: nil),
            Toolchain(tool: "Go", version: "1.23.3", path: "/opt/homebrew/bin/go", note: nil),
            Toolchain(tool: "Rust", version: "1.82.0", path: "/Users/demo/.cargo/bin/rustc", note: nil),
            Toolchain(tool: "Ruby", version: "3.3.5", path: "/Users/demo/.rbenv/shims/ruby", note: "rbenv global version from ~/.rbenv/version; the shim wasn't run"),
        ]
        let sim = Simulator(udid: "5E1D0C4B-DEMO-4A2B-9C8D-000000000001", name: "iPhone 17 Pro", runtime: "iOS 26.1")
        m.simulators = .ok([sim])
        m.demoSimUsage = [sim.udid: (cpu: 23.5, memory: UInt64(1.2 * gb), processes: 64)]
    }

    /// The port finder in demo mode: answers from the invented dev servers only.
    static func portAnswer(_ port: Int, model m: DeveloperModel, containers: [DockerContainer]) -> PortAnswer {
        let socks = (m.servers?.servers ?? []).filter { $0.ports.contains(port) }.map {
            ListeningSocket(process: $0.process, pid: $0.identity.pid, proto: "TCP", family: $0.address.contains(":") ? "IPv6" : "IPv4", address: $0.address, port: port)
        }
        return PortAnswer(port: port, sockets: socks, containers: containers, coverage: .allProcesses)
    }
}
