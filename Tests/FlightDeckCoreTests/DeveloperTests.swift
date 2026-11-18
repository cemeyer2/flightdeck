// Tests for the Developer destination's parsers and classifiers: dev-server and build classification from synthetic
// command lines, docker ps/stats JSON lines, brew services JSON, simctl JSON and toolchain version banners. The few
// live checks skip when the tool they need isn't installed (CI runs on GitHub's macOS VMs).
import XCTest
@testable import FlightDeckCore

final class DeveloperTests: XCTestCase {
    func kind(_ exe: String, _ args: String) -> String? {
        DevClassifier.server(executable: exe, args: args.split(separator: " ").map(String.init))?.name
    }

    func testServerClassification() {
        let cases: [(String, String, String?)] = [
            ("/opt/homebrew/Cellar/node/22.3.0/bin/node", "node /Users/me/app/node_modules/.bin/vite --port 5173", "Vite"),
            ("/usr/local/bin/node", "node /Users/me/site/node_modules/.bin/next dev", "Next.js"),
            ("/usr/local/bin/node", "next-server (v14.2.3)", "Next.js"),
            ("/usr/local/bin/node", "node node_modules/webpack-dev-server/bin/webpack-dev-server.js", "webpack dev server"),
            ("/usr/local/bin/node", "node node_modules/.bin/webpack serve --mode development", "webpack dev server"),
            ("/usr/local/bin/node", "node server.js", "Node.js"),
            ("/Users/me/.bun/bin/bun", "bun run dev", "Bun"),
            ("/opt/homebrew/bin/deno", "deno run --allow-net main.ts", "Deno"),
            ("/opt/homebrew/Cellar/python@3.12/3.12.4/Frameworks/Python.framework/Versions/3.12/bin/python3.12",
             "/Users/me/api/.venv/bin/python /Users/me/api/.venv/bin/uvicorn main:app --reload", "uvicorn"),
            ("/usr/bin/python3", "python3 manage.py runserver 0.0.0.0:8000", "Django runserver"),
            ("/usr/bin/python3", "python3 -m flask run", "Flask"),
            ("/opt/homebrew/bin/python3.11", "gunicorn: master [app:wsgi]", "gunicorn"),
            ("/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3.12 /opt/homebrew/bin/jupyter-lab", "JupyterLab"),
            ("/usr/bin/python3", "python3 -m http.server 8000", "Python http.server"),
            ("/Users/me/.rbenv/versions/3.3.0/bin/ruby", "puma 6.4.2 (tcp://localhost:3000) [blog]", "Puma"),
            ("/Users/me/.rbenv/versions/3.3.0/bin/ruby", "ruby bin/rails server", "Rails"),
            ("/usr/bin/java", "java -Xmx2g -cp gradle-launcher.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.7", "Gradle daemon"),
            ("/usr/bin/java", "java -jar build/libs/demo-0.0.1-SNAPSHOT.jar --spring.profiles.active=dev -Dloader=org.springframework.boot", "Spring Boot"),
            ("/usr/bin/java", "java -jar target/app.jar", "Java (app.jar)"),
            ("/private/var/folders/x/T/go-build123/b001/exe/main", "main", "Go program (go run)"),
            ("/Users/me/proj/target/debug/proj", "proj", "Rust program (cargo target)"),
            ("/opt/homebrew/bin/php", "php -S localhost:8080", "PHP built-in server"),
            ("/opt/homebrew/bin/php", "php artisan serve", "Laravel (artisan serve)"),
            ("/opt/homebrew/opt/postgresql@16/bin/postgres", "postgres -D /opt/homebrew/var/postgresql@16", "PostgreSQL"),
            ("/opt/homebrew/opt/redis/bin/redis-server", "redis-server 127.0.0.1:6379", "Redis"),
            ("/opt/homebrew/opt/mysql/bin/mysqld", "mysqld --basedir=/opt/homebrew", "MySQL"),
            ("/opt/homebrew/bin/mongod", "mongod --config x", "MongoDB"),
            ("/Applications/Ollama.app/Contents/Resources/ollama", "ollama serve", "Ollama"),
            ("/Applications/LM Studio.app/Contents/MacOS/LM Studio", "LM Studio", "LM Studio"),
            ("/Applications/Docker.app/Contents/MacOS/com.docker.backend", "com.docker.backend", "Docker port forward"),
            ("/Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper", "OrbStack Helper", "OrbStack port forward"),
            // Not developer tools: ordinary apps that listen.
            ("/Applications/Spotify.app/Contents/MacOS/Spotify", "Spotify", nil),
            ("/usr/libexec/rapportd", "rapportd", nil),
            ("/Applications/Raycast.app/Contents/MacOS/Raycast", "Raycast", nil),
        ]
        for (exe, args, want) in cases { XCTAssertEqual(kind(exe, args), want, "\(exe) \(args)") }
        XCTAssertEqual(DevClassifier.server(executable: "/usr/local/bin/node", args: ["node", "x"])?.family, .javascript)
        XCTAssertEqual(DevClassifier.server(executable: "/opt/homebrew/bin/postgres", args: [])?.family, .database)
    }

    func testBuildClassification() {
        XCTAssertEqual(DevClassifier.build(name: "swift-frontend", args: nil), "Swift compiler")
        XCTAssertEqual(DevClassifier.build(name: "clang", args: nil), "clang")
        XCTAssertEqual(DevClassifier.build(name: "ld64", args: nil), "linker")
        XCTAssertEqual(DevClassifier.build(name: "xcodebuild", args: nil), "xcodebuild")
        XCTAssertEqual(DevClassifier.build(name: "cargo", args: nil), "cargo")
        XCTAssertEqual(DevClassifier.build(name: "esbuild", args: nil), "esbuild")
        XCTAssertEqual(DevClassifier.build(name: "node", args: ["node", "/p/node_modules/.bin/tsc", "-p", "."]), "tsc")
        XCTAssertNil(DevClassifier.build(name: "node", args: ["node", "server.js"]))
        XCTAssertNil(DevClassifier.build(name: "node", args: nil))   // unreadable command line: not claimed
        XCTAssertEqual(DevClassifier.build(name: "java", args: ["java", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"]), "Gradle")
        XCTAssertNil(DevClassifier.build(name: "Safari", args: nil))
        XCTAssertTrue(DevClassifier.needsArguments("node")); XCTAssertFalse(DevClassifier.needsArguments("clang"))
    }

    func testDevServerGrouping() {
        let socks = [
            ListeningSocket(process: "node", pid: 10, proto: "TCP", family: "IPv4", address: "127.0.0.1", port: 5173),
            ListeningSocket(process: "node", pid: 10, proto: "TCP", family: "IPv6", address: "::1", port: 5173),
            ListeningSocket(process: "node", pid: 10, proto: "TCP", family: "IPv4", address: "*", port: 24678),
            ListeningSocket(process: "Spotify", pid: 11, proto: "TCP", family: "IPv4", address: "*", port: 57621),
            ListeningSocket(process: "postgres", pid: 12, proto: "TCP", family: "IPv4", address: "127.0.0.1", port: 5432),
            ListeningSocket(process: "node", pid: 13, proto: "UDP", family: "IPv4", address: "*", port: 9999),
        ]
        let exe: [Int32: String] = [10: "/usr/local/bin/node", 11: "/Applications/Spotify.app/Contents/MacOS/Spotify", 12: "/opt/homebrew/bin/postgres"]
        let r = DevServers.build(from: ListeningScan(sockets: socks, coverage: .allProcesses), isOwn: { $0 != 12 },
                                 identity: { ProcessIdentity(pid: $0, startTime: 1) }, executable: { exe[$0] ?? "" },
                                 arguments: { $0 == 10 ? ["node", "node_modules/.bin/vite"] : nil }, cwd: { _ in .value("/Users/me/app") })
        XCTAssertEqual(r.servers.count, 1)   // postgres belongs to another user; node's UDP socket is ignored
        XCTAssertEqual(r.servers[0].kind.name, "Vite")
        XCTAssertEqual(r.servers[0].ports, [5173, 24678])
        XCTAssertEqual(r.servers[0].exposure, .allInterfaces)
        XCTAssertEqual(r.servers[0].url(port: 5173)?.absoluteString, "http://localhost:5173")
        XCTAssertEqual(r.otherOwnListeners, ["Spotify"])
    }

    func testParsePort() {
        XCTAssertEqual(DevServers.parsePort("3000"), 3000)
        XCTAssertEqual(DevServers.parsePort(" localhost:8080 "), 8080)
        XCTAssertEqual(DevServers.parsePort(":5432"), 5432)
        XCTAssertEqual(DevServers.parsePort("http://127.0.0.1:5173/path"), 5173)
        XCTAssertNil(DevServers.parsePort("0")); XCTAssertNil(DevServers.parsePort("70000")); XCTAssertNil(DevServers.parsePort("abc"))
    }

    /// Lines in the shape of `docker ps -a --no-trunc --format '{{json .}}'` (Docker 27), IDs shortened for readability.
    static let ps = """
    {"Command":"\\"/docker-entrypoint.…\\"","CreatedAt":"2026-11-17 09:12:01 +0100 CET","ID":"3f1c2a9b7d10","Image":"nginx:1.27","Labels":"com.docker.compose.project=shop,com.docker.compose.service=web","LocalVolumes":"0","Mounts":"","Names":"shop-web-1","Networks":"shop_default","Ports":"0.0.0.0:8080->80/tcp, [::]:8080->80/tcp","RunningFor":"2 hours ago","Size":"0B","State":"running","Status":"Up 2 hours"}
    {"Command":"\\"docker-entrypoint.s…\\"","CreatedAt":"2026-11-10 10:00:00 +0100 CET","ID":"8a7b6c5d4e3f","Image":"postgres:16","Labels":"","LocalVolumes":"1","Mounts":"pgdata","Names":"pg","Networks":"bridge","Ports":"","RunningFor":"7 days ago","Size":"0B","State":"exited","Status":"Exited (0) 3 days ago"}
    {"ID":"aa11","Image":"old","Names":"legacy","Ports":"0.0.0.0:9000-9002->9000-9002/tcp","Status":"Up 5 minutes"}
    WARNING: something that isn't JSON
    """
    static let stats = """
    {"BlockIO":"12.3MB / 4.1kB","CPUPerc":"12.50%","Container":"3f1c2a9b7d10","ID":"3f1c2a9b7d10","MemPerc":"0.39%","MemUsage":"30.5MiB / 7.654GiB","Name":"shop-web-1","NetIO":"1.2kB / 830B","PIDs":"9"}
    {"BlockIO":"--","CPUPerc":"--","Container":"aa11","ID":"aa11","MemPerc":"--","MemUsage":"-- / --","Name":"legacy","NetIO":"--","PIDs":"0"}
    """

    func testDockerPS() {
        let c = DockerCLI.parsePS(Self.ps)
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c[0].name, "shop-web-1"); XCTAssertEqual(c[0].state, "running"); XCTAssertEqual(c[0].composeProject, "shop")
        XCTAssertEqual(c[0].publishedPorts, [8080])
        XCTAssertEqual(c[1].state, "exited"); XCTAssertFalse(c[1].isRunning); XCTAssertEqual(c[1].publishedPorts, [])
        XCTAssertEqual(c[2].state, "running")   // no State key: derived from "Up …"
        XCTAssertEqual(c[2].publishedPorts, [9000, 9001, 9002])
    }

    func testDockerStats() throws {
        let s = DockerCLI.parseStats(Self.stats)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(try XCTUnwrap(s[0].cpu), 12.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(s[0].memoryBytes), 30.5 * 1_048_576, accuracy: 1)
        XCTAssertEqual(s[0].pids, 9)
        XCTAssertNil(s[1].cpu); XCTAssertNil(s[1].memoryBytes)   // "--" stays unknown, never 0
        XCTAssertEqual(DockerCLI.bytes("1.2kB"), 1200); XCTAssertEqual(DockerCLI.bytes("2GiB"), 2 * 1_073_741_824)
        let c = DockerCLI.parsePS(Self.ps)
        let dict = Dictionary(uniqueKeysWithValues: s.map { ($0.id, $0) })
        XCTAssertEqual(DockerCLI.stats(for: c[0], in: dict)?.name, "shop-web-1")
        XCTAssertNil(DockerCLI.stats(for: c[1], in: dict))
    }

    /// The shape of `brew services list --json` (Homebrew 4.x).
    static let brew = """
    [
      {"name": "postgresql@16", "status": "started", "user": "me", "file": "/Users/me/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist", "exit_code": 0},
      {"name": "redis", "status": "none", "user": null, "file": "/opt/homebrew/opt/redis/homebrew.mxcl.redis.plist", "exit_code": null},
      {"name": "nginx", "status": "error", "user": "root", "file": "/Library/LaunchDaemons/homebrew.mxcl.nginx.plist", "exit_code": 78}
    ]
    """

    func testBrewServices() throws {
        let s = try XCTUnwrap(Brew.parse(Self.brew))
        XCTAssertEqual(s.map(\.name), ["postgresql@16", "redis", "nginx"])
        XCTAssertTrue(s[0].isRunning); XCTAssertEqual(s[0].user, "me"); XCTAssertEqual(s[0].exitCode, 0)
        XCTAssertNil(s[1].user); XCTAssertNil(s[1].exitCode); XCTAssertFalse(s[1].isRunning)
        XCTAssertEqual(s[2].status, "error"); XCTAssertEqual(s[2].exitCode, 78)
        XCTAssertEqual(Brew.parse("[]")?.count, 0)
        XCTAssertNil(Brew.parse("Error: unknown command"))
        XCTAssertEqual(Brew.perform(.start, service: "--force"), Brew.locate() == nil ? "Homebrew is no longer installed" : "invalid service name")
    }

    func testSimctl() throws {
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-2":[{"lastBootedAt":"2026-11-18T08:00:00Z","dataPath":"/Users/me/Library/Developer/CoreSimulator/Devices/1A2B/data","udid":"1A2B","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-16","state":"Booted","name":"iPhone 16"}],
        "com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[{"udid":"3C4D","state":"Shutdown","name":"Apple Watch"}],
        "com.apple.CoreSimulator.SimRuntime.xrOS-2-1":[]}}
        """
        let s = try XCTUnwrap(DevActivity.parseSimctl(json))
        XCTAssertEqual(s, [Simulator(udid: "1A2B", name: "iPhone 16", runtime: "iOS 18.2")])
        XCTAssertEqual(DevActivity.parseSimctl(#"{"devices":{}}"#)?.count, 0)
        XCTAssertNil(DevActivity.parseSimctl("xcrun: error: unable to find utility \"simctl\""))
        XCTAssertEqual(DevActivity.runtimeName("iOS 12.4"), "iOS 12.4")
    }

    func testVersions() {
        XCTAssertEqual(Toolchains.version(tool: "swift", output: "swift-driver version: 1.120.5 Apple Swift version 6.1 (swiftlang-6.1.0.110.21 clang-1700.0.13.3)\nTarget: arm64-apple-macosx15.0"), "6.1")
        XCTAssertEqual(Toolchains.version(tool: "node", output: "v22.3.0\n"), "22.3.0")
        XCTAssertEqual(Toolchains.version(tool: "python3", output: "Python 3.12.4"), "3.12.4")
        XCTAssertEqual(Toolchains.version(tool: "go", output: "go version go1.22.4 darwin/arm64"), "1.22.4")
        XCTAssertEqual(Toolchains.version(tool: "rustc", output: "rustc 1.79.0 (129f3b996 2024-06-10)"), "1.79.0")
        XCTAssertEqual(Toolchains.version(tool: "java", output: "openjdk version \"21.0.3\" 2024-04-16\nOpenJDK Runtime Environment"), "21.0.3")
        XCTAssertEqual(Toolchains.version(tool: "java", output: "java version \"1.8.0_402\""), "1.8.0_402")
        XCTAssertEqual(Toolchains.version(tool: "ruby", output: "ruby 3.3.0 (2023-12-25 revision 5124f9ac75) [arm64-darwin23]"), "3.3.0")
        XCTAssertNil(Toolchains.version(tool: "ruby", output: "rbenv: ruby: command not found"))
        XCTAssertEqual(Toolchains.xcodeVersion("Xcode 16.0\nBuild version 16A242d\n"), "16.0 (16A242d)")
        XCTAssertNil(Toolchains.xcodeVersion("xcode-select: error: tool 'xcodebuild' requires Xcode"))
        XCTAssertEqual(Toolchains.shimManager("/Users/me/.rbenv/shims/ruby"), "rbenv")
        XCTAssertNil(Toolchains.shimManager("/opt/homebrew/bin/ruby"))
        XCTAssertEqual(Toolchains.asdfVersion("nodejs 20.11.0\npython 3.12.1 3.11.7\n", plugin: "python"), "3.12.1")
    }

    func testEngineAttribution() {
        XCTAssertEqual(DevActivity.engine(name: "com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"), "Docker Desktop")
        XCTAssertEqual(DevActivity.engine(name: "OrbStack Helper", path: "/Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper"), "OrbStack")
        XCTAssertEqual(DevActivity.engine(name: "limactl", path: "/opt/homebrew/bin/limactl"), "Colima / Lima")
        XCTAssertNil(DevActivity.engine(name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari"))
    }

    /// Live: the toolchain probe completes and never reports a version without a path.
    func testLiveToolchains() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/xcode-select") else { throw XCTSkip("no xcode-select") }
        for t in Toolchains.detect() where t.version != nil { XCTAssertNotNil(t.path, t.tool) }
    }

    /// Live: the DevShell runner reports the exit status and stderr separately.
    func testRunner() throws {
        let r = try XCTUnwrap(DevShell.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"]))
        XCTAssertEqual(r.status, 3); XCTAssertEqual(r.stdout, "out\n"); XCTAssertEqual(r.reason, "err"); XCTAssertFalse(r.ok)
        let slow = try XCTUnwrap(DevShell.run("/bin/sleep", ["5"], timeout: 0.3))
        XCTAssertTrue(slow.timedOut)
    }
}
