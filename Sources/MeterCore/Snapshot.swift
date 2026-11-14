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
}

/// Not thread-safe; the app confines it to one serial queue.
public final class Sampler: @unchecked Sendable {
    public let cpu = CPUSampler()
    let memory = MemorySampler()
    let disk = DiskSampler()
    let network = NetworkSampler()
    let power = PowerSampler()
    public let processes = ProcessSampler()
    public init() {}

    public func sample() -> Snapshot {
        Snapshot(time: Date(), cpu: cpu.sample(), memory: memory.sample(), disk: disk.sample(),
                 network: network.sample(), power: power.sample(), gpu: SystemInfo.gpuUtilization(),
                 processes: processes.sample())
    }
}

/// `.mltrace` file: zlib-compressed JSON of frames.
public struct Trace: Codable, Sendable {
    public static let fileExtension = "mltrace"
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
        c.processes = Array(s.processes.sorted { $0.cpu + Double($0.memory) / 1e10 > $1.cpu + Double($1.memory) / 1e10 }.prefix(keep))
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
