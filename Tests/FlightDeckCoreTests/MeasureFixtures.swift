// Synthetic frames for the measure / query_metrics tests: snapshots cloned from one real sample with every field the
// measurement reads overridden, and processes built from scratch (identity, parent, cumulative counters).
import XCTest
@testable import FlightDeckCore

enum MeasureFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func proc(_ name: String, pid: Int32, ppid: Int32, start: Date, cpuTime: Double, mem: UInt64 = 100 << 20,
                     energy: Double? = nil, disk: UInt64 = 0, path: String? = nil) -> ProcessSample {
        var p = BlackBoxTests.base.processes[0]
        p.identity = ProcessIdentity(pid: pid, startTime: UInt64(start.timeIntervalSince1970 * 1e6))
        p.ppid = ppid; p.name = name; p.path = path ?? "/usr/bin/\(name)"; p.user = "me"; p.uid = 501
        p.restricted = false; p.cpu = 0; p.cpuTime = cpuTime; p.memory = mem; p.threads = 1
        p.energyTotal = energy; p.energyWatts = nil; p.diskRead = disk; p.diskWritten = 0; p.diskReadBps = 0; p.diskWriteBps = 0
        p.network = nil; p.gpu = nil; p.notResponding = nil; p.powerAssertions = nil; p.translated = nil; p.wakeups = 0
        return p
    }

    /// A frame at `t` with the given processes and system readings; nil readings are "unavailable".
    static func frame(_ t: Date, _ procs: [ProcessSample], cpu: Double? = 50, watts: Double? = 36, hottest: Double? = 60,
                      diskTotal: UInt64 = 0, netTotal: UInt64 = 0, thermal: Int = 0) -> Snapshot {
        var s = BlackBoxTests.base
        s.time = t
        s.cpu.total = cpu.map { .value($0) } ?? .unavailable("warming up")
        s.cpu.user = .value((cpu ?? 0) * 0.7); s.cpu.system = .value((cpu ?? 0) * 0.3)
        s.cpu.cores = Array(repeating: s.cpu.cores.first ?? CoreSample(index: 0, kind: .performance, user: 0, system: 0), count: 10)
        s.memory.measured = true; s.memory.used = 8 << 30; s.memory.total = 16 << 30
        s.memory.pressure = .value(30); s.memory.swapUsed = .value(0)
        s.disk.devices = [DiskDevice(name: "disk0", readBps: 0, writeBps: 0, totalRead: diskTotal, totalWritten: diskTotal / 2)]
        s.disk.readBps = .value(0); s.disk.writeBps = .value(0)
        s.network.inBps = .value(0); s.network.outBps = .value(0); s.network.totalIn = netTotal; s.network.totalOut = netTotal / 4
        s.power.systemWatts = watts.map { .value($0) } ?? .unavailable("no sensor")
        s.power.hottest = hottest.map { .value($0) } ?? .unavailable("no sensors")
        s.power.thermalState = thermal; s.power.battery = nil
        s.gpu = .value(5)
        s.processes = procs
        return s
    }

    /// A build: zsh (running before the window) starts xcodebuild inside it, which spawns three compilers, one of
    /// which spawns a helper. Frames every 10 s from t0 to t0+60; the window is [t0+10, t0+60].
    /// - xcodebuild is seen four times, CPU time 2 → 10;
    /// - each compiler is seen once with 3 CPU-s (born in the window, so all of it counts);
    /// - the helper is seen once with 1 CPU-s; its parent compiler was recorded, so it joins the tree;
    /// - an orphan whose parent was never recorded, and an older process reusing a compiler's PID, stay out;
    /// - Safari runs throughout: 100 CPU-s at the baseline frame, 130 at the end.
    static func build() -> [Snapshot] {
        let t = { (s: Double) in t0.addingTimeInterval(s) }
        let zsh = { (c: Double) in proc("zsh", pid: 100, ppid: 1, start: t(-1000), cpuTime: c) }
        let xb = { (c: Double, m: UInt64) in proc("xcodebuild", pid: 200, ppid: 100, start: t(12), cpuTime: c, mem: m, energy: c * 10) }
        let safari = { (c: Double) in proc("Safari", pid: 50, ppid: 1, start: t(-5000), cpuTime: c, mem: 2 << 30,
                                          path: "/Applications/Safari.app/Contents/MacOS/Safari") }
        let reused = proc("other", pid: 301, ppid: 1, start: t(-500), cpuTime: 50)
        func cc(_ pid: Int32, _ at: Double) -> ProcessSample { proc("swift-frontend", pid: pid, ppid: 200, start: t(at), cpuTime: 3, mem: 500 << 20, disk: 1_000_000) }
        return [
            frame(t(0), [zsh(5), safari(100), reused]),
            frame(t(10), [zsh(5), safari(105), reused]),
            frame(t(20), [zsh(5), safari(110), xb(2, 200 << 20), cc(301, 15)]),
            frame(t(30), [zsh(5), safari(115), xb(6, 300 << 20), cc(302, 22), cc(303, 25),
                          proc("swift-helper", pid: 400, ppid: 301, start: t(18), cpuTime: 1),
                          proc("orphan", pid: 500, ppid: 999, start: t(26), cpuTime: 7)]),
            frame(t(40), [zsh(5), safari(120), xb(10, 250 << 20)]),
            frame(t(50), [zsh(5), safari(125)]),
            frame(t(60), [zsh(5), safari(130)]),
        ]
    }
}

/// A data source serving one fixed trace for every tier, with a configurable interval and standalone flag.
final class TraceSource: MCPDataSource, @unchecked Sendable {
    var standalone = false
    var frames: [Snapshot] = []
    var interval = 10.0
    var blackBoxConfig = BlackBox.Config()
    func snapshot() async -> Snapshot? { frames.last }
    func findings() async -> [Finding] { [] }
    func incidents() async -> [Incident] { [] }
    func reports(since: Date) async -> [DiagnosticReport] { [] }
    func blackBox(_ tier: BlackBox.Tier, from: Date, to: Date) async -> Trace? {
        let f = frames.filter { $0.time >= from && $0.time <= to }
        return f.isEmpty ? nil : Trace(host: "Test", model: "Mac", interval: interval, frames: f)
    }
    func dailyHistory() async -> DailyLog.History? { nil }
    func checkup() async -> [CheckResult] { [] }
}

extension XCTestCase {
    /// A marks store in a fresh temporary folder.
    func tempMarks() -> MarkStore {
        MarkStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("marks-\(UUID().uuidString)/marks.json"))
    }
}
