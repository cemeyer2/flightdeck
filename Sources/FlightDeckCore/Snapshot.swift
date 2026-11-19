import Foundation
// The data model's centre: `Snapshot` (one frame), `Sampler` (builds a frame from every sampler each tick) and
// `Trace` (a list of frames on disk, used by recordings and every black-box segment).

/// One complete telemetry frame. Everything the live UI shows comes from a Snapshot, so the
/// Flight Recorder can replay any frame through the same views.
public struct Snapshot: Codable, Sendable {
    /// When the frame was assembled. Analyzer, rules, black box and replay all use this time, not the wall clock.
    public var time: Date
    public var cpu: CPUSample
    public var memory: MemorySample
    public var disk: DiskSample
    public var network: NetworkSample
    public var power: PowerSample
    /// Whole-GPU utilisation %, 0..100.
    public var gpu: Measured<Double>
    /// Every process when live; recorded frames keep only the busiest few (see `Trace.trimmed`).
    public var processes: [ProcessSample]
    // Optional so traces recorded before these existed still decode.
    public var wifi: WiFiInfo? = nil
    /// Latest opt-in probe results (empty when probing is off).
    public var latency: [LatencyResult]? = nil
    /// SMART health of internal SSDs (refreshed every 5 minutes).
    public var drives: [DriveHealth]? = nil
    /// GPU utilisation, frequency, power, memory, recoveries, per-process GPU time; CPU cluster frequencies.
    public var gpuDetail: GPUDetail? = nil
}

/// Runs every sampler once and stitches the results into a `Snapshot`, merging per-process extras (network, hang
/// state, power assertions, GPU time) into the process list. Several samplers compute rates from deltas, so the
/// first call after launch only primes them.
/// Not thread-safe; the app confines it to one serial queue (the Engine's sampling queue).
public final class Sampler: @unchecked Sendable {
    public let cpu = CPUSampler()
    let memory = MemorySampler()
    let disk = DiskSampler()
    let network = NetworkSampler()
    let power = PowerSampler()
    public let processes = ProcessSampler()
    let processNetwork = ProcessNetworkSampler()
    // nettop runs on its own serial queue so a slow or stuck run never delays a snapshot; each sample uses the latest
    // finished result (at most about one tick old). All of processNetwork's state is touched only on this queue.
    private let netQueue = DispatchQueue(label: "flightdeck.nettop", qos: .utility)
    private let netLock = NSLock()
    private var latestNet: [Int32: ProcessNetwork]?
    private var latestNetTime: Date?
    private var netRunning = false
    private var lastNetStart = Date.distantPast
    /// Minimum seconds between nettop runs (0 = every sample). The app raises it while no window is visible, which is
    /// the biggest single saving in background cost (each run is a process launch).
    public var networkInterval: TimeInterval = 0
    /// Set by the app while no window is visible: slow-changing, costly sources (temperature sensors, hang checks,
    /// Wi-Fi) refresh less often. Findings that depend on them react a few seconds later; nothing is skipped entirely.
    public var background = false { didSet { power.background = background } }

    /// Starts a nettop run in the background unless one is running or the last started too recently.
    private func refreshNetwork() {
        netLock.lock()
        guard !netRunning, Date().timeIntervalSince(lastNetStart) >= networkInterval else { netLock.unlock(); return }
        netRunning = true; lastNetStart = Date()
        netLock.unlock()
        netQueue.async { [self] in
            let r = processNetwork.sample()
            netLock.lock(); latestNet = r; latestNetTime = Date(); netRunning = false; let procs = destinationProcs; netLock.unlock()
            // Destinations reuse this run's per-flow deltas: no second nettop, O(active flows) of extra work.
            if let destinations, r != nil {
                destinations.ingest(processNetwork.lastFlows, procs: procs, now: Date(), lookups: destinationLookups)
            }
        }
    }
    /// Per-app destinations (DestinationTracker). Set once before the first sample; nil = not collected.
    public var destinations: DestinationTracker?
    /// Whether the tracker may look names up by reverse DNS (Settings). Read on the nettop queue.
    public var destinationLookups = true
    /// The latest process list, for the tracker's PID → app mapping. Guarded by netLock.
    private var destinationProcs: [ProcessSample] = []

    /// The latest per-process network result, or nil if nettop is unavailable or the result is stale (> 15 s old).
    private func currentNetwork() -> [Int32: ProcessNetwork]? {
        netLock.lock(); defer { netLock.unlock() }
        guard let t = latestNetTime, Date().timeIntervalSince(t) < 15 + networkInterval else { return nil }
        return latestNet
    }
    /// Opt-in; its latest results are attached to each snapshot while running.
    public let probe = NetworkProbe()
    private let gpuSampler = GPUSampler()
    // Slow-changing sources refresh on their own cadence to keep FlightDeck's own overhead low.
    private var hangs: [Int32: Bool] = [:], hangsRead: Date?
    private var wifi: WiFiInfo?, wifiRead: Date?
    private var drives: [DriveHealth]?
    private var drivesRead: Date?
    public init() {}

    /// Wi-Fi details, re-read at most every 5 s.
    private func currentWiFi() -> WiFiInfo? {
        if wifiRead.map({ Date().timeIntervalSince($0) >= (background ? 15 : 5) }) ?? true { wifi = WiFiInfo.current(); wifiRead = Date() }
        return wifi
    }

    /// Takes one frame. Called on the sampling queue once per tick; blocks for the duration of the slowest sampler.
    /// Start time last seen for each PID, to notice when macOS reuses a PID for a new process.
    private var pidStarts: [Int32: UInt64] = [:]

    public func sample() -> Snapshot {
        var procs = processes.sample()
        // nettop and the GPU clients only report bare PIDs. If a PID now belongs to a different process (new start
        // time), the old process's running totals must not carry over to it.
        for p in procs where pidStarts[p.pid].map({ $0 != p.identity.startTime }) == true {
            let pid = p.pid
            netQueue.async { [processNetwork, destinations] in processNetwork.forget(pid: pid); destinations?.forget(pid: pid) }
            gpuSampler.forget(pid: pid)
        }
        pidStarts = Dictionary(procs.map { ($0.pid, $0.identity.startTime) }, uniquingKeysWith: { a, _ in a })
        // Per-process network comes from nettop (macOS has no public per-process byte counters). When it ran, a
        // process missing from its output had no traffic, so it gets a real zero; when it didn't run, `network`
        // stays nil (unavailable). `retain` drops running totals for processes that have exited.
        refreshNetwork()
        if let net = currentNetwork() {
            for i in procs.indices {
                procs[i].network = net[procs[i].pid] ?? ProcessNetwork(inBps: 0, outBps: 0, totalIn: 0, totalOut: 0, connections: 0)
            }
            let live = Set(procs.map(\.pid))
            netQueue.async { [processNetwork] in processNetwork.retain(pids: live) }
        }
        // Hang state uses private window-server calls (see HangDetector) and only covers regular Dock apps; other
        // processes stay nil (unknown), never false. Checked every 2 s; SMART data every 5 minutes.
        if hangsRead.map({ Date().timeIntervalSince($0) >= (background ? 6 : 2) }) ?? true { hangs = HangDetector.check(); hangsRead = Date() }
        if !hangs.isEmpty { for i in procs.indices { procs[i].notResponding = hangs[procs[i].pid] } }
        if drivesRead.map({ Date().timeIntervalSince($0) > 300 }) ?? true { drives = DriveHealthReader.read(); drivesRead = Date() }
        let assertions = PowerAssertions.byPID()
        for i in procs.indices { procs[i].powerAssertions = assertions[procs[i].pid] }
        let gd = gpuSampler.sample()
        // Per-process GPU % (already folded per PID by GPUSampler; summing duplicates just keeps the dictionary build safe).
        let gpuByPID = Dictionary(gd.clients.map { ($0.pid, $0.percent) }, uniquingKeysWith: +)
        for i in procs.indices { procs[i].gpu = gpuByPID[procs[i].pid] }
        // After the last mutation of `procs`, so sharing its buffer never forces a copy (the snapshot shares it too).
        if destinations != nil { netLock.lock(); destinationProcs = procs; netLock.unlock() }
        // Empty optional collections are stored as nil, which keeps recorded frames small and means "none".
        let lat = probe.results
        return Snapshot(time: Date(), cpu: cpu.sample(), memory: memory.sample(), disk: disk.sample(),
                        network: network.sample(), power: power.sample(), gpu: SystemInfo.gpuUtilization(),
                        processes: procs, wifi: currentWiFi(), latency: lat.isEmpty ? nil : lat, drives: drives?.isEmpty == false ? drives : nil, gpuDetail: gd)
    }
}

/// `.flightlog` file: zlib-compressed JSON of frames. Used for user recordings, exported traces and every black-box
/// segment, so all of them open in the same replay UI.
public struct Trace: Codable, Sendable {
    public static let fileExtension = "flightlog"
    /// Same format, written before the rename from Meterline. Still opened, never written.
    public static let legacyFileExtensions = ["mltrace"]
    /// File format version. New fields are added as optionals (see `Snapshot`) so old files keep decoding.
    /// Format version. 1: original. 2: process samples may carry cumulative `energyTotal`, and snapshots may carry the
    /// optional GPU/Wi-Fi/drive fields. Readers accept any version: newer fields are optional, older traces decode fine.
    public var version = 2
    public var host: String
    public var model: String
    /// macOS version of the Mac that recorded it (nil in older traces).
    public var osVersion: String? = nil
    /// Nominal seconds between frames. Consumers use it to tell a normal step from a gap (e.g. > 3 intervals).
    public var interval: Double
    public var frames: [Snapshot]

    public init(host: String, model: String, interval: Double, frames: [Snapshot]) {
        self.host = host; self.model = model; self.interval = interval; self.frames = frames
        osVersion = ProcessInfo.processInfo.operatingSystemVersionString   // traces are built on the recording Mac
    }

    /// Recorded frames keep only the top processes to bound file size. The kept set is a union of several "top"
    /// lists so a process that matters for any view survives: ~2/3 of `keep` by load (CPU, with memory as a weak
    /// tie-breaker: 10 GB counts like 1% CPU), ~1/3 by network, plus the top energy users and top 3 GPU users.
    /// Duplicates are removed by identity (PID + start time), so the result can be shorter than the sum.
    public static func trimmed(_ s: Snapshot, keep: Int = 60) -> Snapshot {
        var c = s
        let byLoad = s.processes.sorted { $0.cpu + Double($0.memory) / 1e10 > $1.cpu + Double($1.memory) / 1e10 }.prefix(keep * 2 / 3)
        func net(_ p: ProcessSample) -> Double { (p.network?.inBps ?? 0) + (p.network?.outBps ?? 0) }
        let byNet = s.processes.filter { net($0) > 0 }.sorted { net($0) > net($1) }.prefix(keep / 3)
        var seen = Set<ProcessIdentity>()
        let byEnergy = s.processes.filter { ($0.energyWatts ?? 0) > 0 }.sorted { ($0.energyWatts ?? 0) > ($1.energyWatts ?? 0) }.prefix(max(keep / 5, 3))
        let byGPU = s.processes.filter { ($0.gpu ?? 0) > 0 }.sorted { ($0.gpu ?? 0) > ($1.gpu ?? 0) }.prefix(3)
        c.processes = (Array(byLoad) + Array(byNet) + Array(byEnergy) + Array(byGPU)).filter { seen.insert($0.identity).inserted }
        return c
    }

    /// Dates are stored as seconds since 1970 (Double), so they round-trip with sub-millisecond error; callers
    /// comparing times pad by a millisecond (see `BlackBox.trace`). Written atomically so readers never see half a file.
    public func write(to url: URL) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        let data = try enc.encode(self)
        try (data as NSData).compressed(using: .zlib).write(to: url, options: .atomic)
    }

    /// Throws on unreadable, non-zlib or undecodable files; callers typically skip such files.
    public static func read(from url: URL) throws -> Trace {
        let raw = try Data(contentsOf: url)
        let data = try (raw as NSData).decompressed(using: .zlib) as Data
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try dec.decode(Trace.self, from: data)
    }
}
