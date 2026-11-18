import SwiftUI
import FlightDeckCore

// State behind the Developer destination. Nothing here runs while the page is closed: `appear()` loads everything and
// starts a 5-second timer for the cheap, fast-changing parts (dev servers and containers); Homebrew services and
// simulators (each a ~1 s tool start) refresh on appear, on Refresh, after an action and every 30 s; toolchains only on
// appear and Refresh. `disappear()` stops the timer. Build activity, container-engine usage and simulator CPU need no
// tools at all: they are derived from the process sample the Engine already takes.
//
// Every action (stop a server, start/stop a container or service) goes through a confirmation (`confirm`) first, and
// nothing is ever run in demo mode, which shows `DeveloperDemo` data instead.

/// A pending "are you sure?" question. `perform` runs only when the user confirms.
struct DevConfirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var button: String
    var destructive = true
    var perform: @MainActor () -> Void
}

/// The port finder's answer: who listens on the port, and which containers publish it.
struct PortAnswer {
    var port: Int
    var sockets: [ListeningSocket]
    var containers: [DockerContainer]
    var coverage: ListeningScan.Coverage
}

@MainActor
final class DeveloperModel: ObservableObject {
    @Published var servers: DevServerScan?
    @Published var docker: DockerStatus?
    @Published var brew: BrewStatus?
    @Published var toolchains: [Toolchain]?
    @Published var simulators: SimulatorStatus?
    /// Which loads are in flight ("servers", "docker", "brew", "tools", "sims"), so each runs at most once at a time.
    @Published private(set) var busy: Set<String> = []
    @Published var confirm: DevConfirmation?
    /// The outcome of the last action, shown under the header.
    @Published var notice: String?
    @Published var portQuery = ""
    @Published var portAnswer: PortAnswer?
    @Published var portError: String?

    let demo: Bool
    /// Invented CPU/memory for demo dev servers (real ones are read from the live sample instead).
    var demoUsage: [ProcessIdentity: (cpu: Double, memory: UInt64)] = [:]
    var demoBuilds: [BuildActivity] = [], demoEngines: [EngineUsage] = [], demoSimUsage: [String: (cpu: Double, memory: UInt64, processes: Int)] = [:]
    private var timer: Timer?
    private var ticks = 0
    /// Command lines of own processes by identity, for the build and simulator classifiers. A process's argv is read once.
    private var argsCache: [ProcessIdentity: [String]] = [:]

    /// `demo` defaults to the app's demo mode; renders pass it explicitly.
    init(demo: Bool? = nil) {
        let demo = demo ?? Demo.isEnabled
        self.demo = demo
        if demo { DeveloperDemo.fill(self) }
    }

    func appear() {
        guard !demo else { return }
        refreshFast(); refreshSlow()
        if toolchains == nil { loadToolchains() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ticks += 1
                self.refreshFast()
                if self.ticks % 6 == 0 { self.refreshSlow() }
            }
        }
    }

    func disappear() { timer?.invalidate(); timer = nil }

    /// The Refresh button: everything, including the toolchain probe.
    func refreshAll() {
        guard !demo else { return }
        refreshFast(); refreshSlow(); loadToolchains()
    }

    func refreshFast() {
        load("servers", { DevServers.scan() }) { self.servers = $0 }
        load("docker", { DockerCLI.status() }) { self.docker = $0 }
    }

    func refreshSlow() {
        load("brew", { Brew.services() }) { self.brew = $0 }
        load("sims", { DevActivity.bootedSimulators() }) { self.simulators = $0 }
    }

    func loadToolchains() { load("tools", { Toolchains.detect() }) { self.toolchains = $0 } }

    /// Runs `work` off the main thread unless the same load is already running, then hands the result to `done`.
    private func load<T: Sendable>(_ key: String, _ work: @escaping @Sendable () -> T, _ done: @escaping @MainActor (T) -> Void) {
        guard !demo, !busy.contains(key) else { return }
        busy.insert(key)
        Task.detached {
            let v = work()
            await MainActor.run { done(v); self.busy.remove(key) }
        }
    }

    // MARK: Live joins with the Engine's process sample

    /// argv for one of this user's processes (cached per identity); nil for other users' processes, which the kernel
    /// won't show.
    func arguments(_ p: ProcessSample) -> [String]? {
        guard p.uid == getuid() else { return nil }
        if let a = argsCache[p.identity] { return a }
        guard let a = DevShell.arguments(of: p.pid) else { return nil }
        if argsCache.count > 2000 { argsCache.removeAll() }   // bounded: build tools spawn many short-lived processes
        argsCache[p.identity] = a
        return a
    }

    /// CPU (% of one core) and memory for a dev server, from the current sample (or demo data). nil when the process
    /// isn't in the sample yet, or when the screen shows a replayed recording.
    func usage(_ s: DevServer, in snap: Snapshot?) -> (cpu: Double, memory: UInt64)? {
        if demo { return demoUsage[s.identity] }
        return snap?.processes.first { $0.identity == s.identity }.map { ($0.cpu, $0.memory) }
    }

    func builds(_ snap: Snapshot?) -> [BuildActivity] {
        demo ? demoBuilds : DevActivity.builds(snap?.processes ?? [], args: arguments)
    }

    func engines(_ snap: Snapshot?) -> [EngineUsage] { demo ? demoEngines : DevActivity.engines(snap?.processes ?? []) }

    func simulatorUsage(_ sims: [Simulator], _ snap: Snapshot?) -> [String: (cpu: Double, memory: UInt64, processes: Int)] {
        demo ? demoSimUsage : DevActivity.simulatorUsage(sims, procs: snap?.processes ?? [], args: arguments)
    }

    // MARK: Actions (always confirmed, never in demo mode)

    private func refuseInDemo() -> Bool {
        if demo { notice = "Demo mode: nothing was changed." }
        return demo
    }

    /// Asks, then sends SIGTERM to a dev server. If it is still the same process 3 s later, offers SIGKILL.
    func askStop(_ s: DevServer) {
        confirm = DevConfirmation(
            title: "Stop \(s.kind.name) (PID \(s.identity.pid))?",
            message: "Sends SIGTERM, which asks it to shut down cleanly (port \(s.ports.map(String.init).joined(separator: ", "))). If it is still running after 3 seconds you'll be offered a force stop.",
            button: "Stop") { [weak self] in self?.signal(s, SIGTERM) }
    }

    private func signal(_ s: DevServer, _ sig: Int32) {
        guard !refuseInDemo() else { return }
        // Own processes only (the kernel would refuse others anyway); `send` re-checks the identity right before kill(2).
        guard DevShell.isOwn(s.identity.pid) else { notice = "\(s.kind.name) isn't your process; nothing was sent."; return }
        do { try ProcessSampler.send(sig, to: s.identity) } catch { notice = error.localizedDescription; return }
        notice = sig == SIGKILL ? "Sent SIGKILL to \(s.kind.name) (PID \(s.identity.pid))." : "Sent SIGTERM to \(s.kind.name) (PID \(s.identity.pid))."
        guard sig == SIGTERM else { refreshFast(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if ProcessSampler.identity(of: s.identity.pid) == s.identity {
                self.confirm = DevConfirmation(
                    title: "\(s.kind.name) is still running",
                    message: "PID \(s.identity.pid) ignored SIGTERM for 3 seconds. Force stop it with SIGKILL? It gets no chance to save state or clean up.",
                    button: "Force Stop") { [weak self] in self?.signal(s, SIGKILL) }
            } else {
                self.notice = "\(s.kind.name) (PID \(s.identity.pid)) stopped."
            }
            self.refreshFast()
        }
    }

    func askContainer(_ a: DockerCLI.Action, _ c: DockerContainer) {
        confirm = DevConfirmation(
            title: "\(a.rawValue.capitalized) container “\(c.name)”?",
            message: "Runs `docker \(a.rawValue) \(c.id.prefix(12))` (image \(c.image)).", button: a.rawValue.capitalized,
            destructive: a != .start) { [weak self] in
                guard let self, !self.refuseInDemo() else { return }
                self.notice = "docker \(a.rawValue) \(c.name)…"
                let id = c.id
                Task.detached {
                    let err = DockerCLI.perform(a, containerID: id)
                    await MainActor.run { self.notice = err.map { "docker \(a.rawValue) \(c.name) failed: \($0)" } ?? "docker \(a.rawValue) \(c.name): done."; self.refreshFast() }
                }
            }
    }

    func askService(_ a: Brew.Action, _ s: BrewService) {
        confirm = DevConfirmation(
            title: "\(a.rawValue.capitalized) Homebrew service “\(s.name)”?",
            message: "Runs `brew services \(a.rawValue) \(s.name)`." + (a == .start ? " This also registers it to start at login." : ""),
            button: a.rawValue.capitalized, destructive: a != .start) { [weak self] in
                guard let self, !self.refuseInDemo() else { return }
                self.notice = "brew services \(a.rawValue) \(s.name)…"
                let name = s.name
                Task.detached {
                    let err = Brew.perform(a, service: name)
                    await MainActor.run { self.notice = err.map { "brew services \(a.rawValue) \(name) failed: \($0)" } ?? "brew services \(a.rawValue) \(name): done."; self.refreshSlow() }
                }
            }
    }

    // MARK: Port finder

    func findPort() {
        portError = nil
        guard let port = DevServers.parsePort(portQuery) else { portAnswer = nil; portError = "Enter a port number from 1 to 65535."; return }
        var containers: [DockerContainer] = []
        if case .ok(_, let list, _, _)? = docker { containers = list.filter { $0.publishedPorts.contains(port) } }
        if demo { portAnswer = DeveloperDemo.portAnswer(port, model: self, containers: containers); return }
        let found = containers
        Task.detached {
            let scan = ListeningPorts.scan()
            let socks = DevServers.find(port: port, in: scan)
            await MainActor.run { self.portAnswer = PortAnswer(port: port, sockets: socks, containers: found, coverage: scan.coverage) }
        }
    }
}
