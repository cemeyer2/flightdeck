import Foundation

/// One complete telemetry frame. Everything the live UI shows comes from a Snapshot, so the
/// Flight Recorder can replay any frame through the same views.
public struct Snapshot: Codable, Sendable {
    public var time: Date
    public var cpu: CPUSample
    public var memory: MemorySample
    public var disk: DiskSample
    public var network: NetworkSample
    public var power: PowerSample
    public var gpu: Measured<Double>
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

/// Not thread-safe; the app confines it to one serial queue.
public final class Sampler: @unchecked Sendable {
    public let cpu = CPUSampler()
    let memory = MemorySampler()
    let disk = DiskSampler()
    let network = NetworkSampler()
    let power = PowerSampler()
    public let processes = ProcessSampler()
    let processNetwork = ProcessNetworkSampler()
    /// Opt-in; its latest results are attached to each snapshot while running.
    public let probe = NetworkProbe()
    private let gpuSampler = GPUSampler()
    private var drives: [DriveHealth]?
    private var drivesRead: Date?
    public init() {}

    public func sample() -> Snapshot {
        var procs = processes.sample()
        if let net = processNetwork.sample() {
            for i in procs.indices {
                procs[i].network = net[procs[i].pid] ?? ProcessNetwork(inBps: 0, outBps: 0, totalIn: 0, totalOut: 0, connections: 0)
            }
            processNetwork.retain(pids: Set(procs.map(\.pid)))
        }
        let hangs = HangDetector.check()
        if !hangs.isEmpty { for i in procs.indices { procs[i].notResponding = hangs[procs[i].pid] } }
        if drivesRead.map({ Date().timeIntervalSince($0) > 300 }) ?? true { drives = DriveHealthReader.read(); drivesRead = Date() }
        let assertions = PowerAssertions.byPID()
        for i in procs.indices { procs[i].powerAssertions = assertions[procs[i].pid] }
        let gd = gpuSampler.sample()
        let gpuByPID = Dictionary(gd.clients.map { ($0.pid, $0.percent) }, uniquingKeysWith: +)
        for i in procs.indices { procs[i].gpu = gpuByPID[procs[i].pid] }
        let lat = probe.results
        return Snapshot(time: Date(), cpu: cpu.sample(), memory: memory.sample(), disk: disk.sample(),
                        network: network.sample(), power: power.sample(), gpu: SystemInfo.gpuUtilization(),
                        processes: procs, wifi: WiFiInfo.current(), latency: lat.isEmpty ? nil : lat, drives: drives?.isEmpty == false ? drives : nil, gpuDetail: gd)
    }
}

/// `.flightlog` file: zlib-compressed JSON of frames.
public struct Trace: Codable, Sendable {
    public static let fileExtension = "flightlog"
    /// Same format, written before the rename from Meterline. Still opened, never written.
    public static let legacyFileExtensions = ["mltrace"]
    public var version = 1
    public var host: String
    public var model: String
    public var interval: Double
    public var frames: [Snapshot]

    public init(host: String, model: String, interval: Double, frames: [Snapshot]) {
        self.host = host; self.model = model; self.interval = interval; self.frames = frames
    }

    /// Recorded frames keep only the top processes to bound file size.
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

    public func write(to url: URL) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        let data = try enc.encode(self)
        try (data as NSData).compressed(using: .zlib).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> Trace {
        let raw = try Data(contentsOf: url)
        let data = try (raw as NSData).decompressed(using: .zlib) as Data
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try dec.decode(Trace.self, from: data)
    }
}
