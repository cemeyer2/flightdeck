import Foundation

// Per-process time series behind the process inspector's charts. Engine records every snapshot's full process
// list here (not just the trimmed list kept in frames), and calls gap() when sampling pauses so the charts
// show a hole rather than stitching the two sides together.
/// Compact recent history for every process (not just the busiest), so any process can be inspected with
/// its past. Written on the sampling queue, read from the UI; internally locked.
public final class ProcessHistory: @unchecked Sendable {
    /// One sample of one process. Stored as Float (not Double) to halve memory, since hundreds of processes
    /// times `capacity` points are kept. Units match ProcessSample: `cpu` in % of one core, `memory` in bytes,
    /// disk and network in bytes/s, `gpu` in %. Network and GPU are nil when that source was unavailable
    /// for the sample (e.g. nettop failed), which is distinct from a measured 0.
    public struct Point: Sendable {
        public var cpu: Float, memory: Float, diskRead: Float, diskWrite: Float
        public var netIn: Float?, netOut: Float?
        public var gpu: Float?
    }
    /// Number of ticks (samples) the window covers; `series` always returns exactly this many slots.
    public let capacity: Int
    /// Monotonic sample counter. Time is measured in ticks, not wall-clock, so a gap is just a tick with no data.
    private var tick = 0
    /// Points per process, in ascending tick order. Keyed by ProcessIdentity (PID + start time) so a reused PID
    /// never inherits a dead process's history.
    private var store: [ProcessIdentity: [(tick: Int, point: Point)]] = [:]
    private let lock = NSLock()

    public init(capacity: Int = 300) { self.capacity = capacity }

    /// Appends one tick's worth of samples. Called by Engine on its sampling queue after every snapshot.
    public func record(_ procs: [ProcessSample]) {
        lock.lock(); defer { lock.unlock() }
        tick += 1
        for p in procs {
            let pt = Point(cpu: Float(p.cpu), memory: Float(p.memory), diskRead: Float(p.diskReadBps), diskWrite: Float(p.diskWriteBps),
                           netIn: p.network.map { Float($0.inBps) }, netOut: p.network.map { Float($0.outBps) },
                           gpu: p.gpu.map(Float.init))
            store[p.identity, default: []].append((tick, pt))
        }
        // Trimming is amortised over 30 ticks to keep per-sample cost low, so a process may briefly hold up to
        // capacity + 30 points; `series` ignores anything outside the window anyway.
        if tick % 30 == 0 {   // trim old points and forget processes gone for a whole window
            let oldest = tick - capacity
            store = store.compactMapValues { pts in
                let kept = pts.drop { $0.tick <= oldest }
                return kept.isEmpty ? nil : Array(kept)
            }
        }
    }

    /// A gap (sampling paused): advances time without data.
    public func gap() { lock.lock(); tick += 1; lock.unlock() }

    /// `capacity` points ending now; nil where the process wasn't sampled.
    /// Index `capacity - 1` is the latest tick. Missing ticks stay nil (gaps, not interpolation).
    public func series(_ id: ProcessIdentity) -> [Point?] {
        lock.lock(); defer { lock.unlock() }
        var out = [Point?](repeating: nil, count: capacity)
        for (t, p) in store[id] ?? [] {
            let i = capacity - 1 - (tick - t)
            if i >= 0 && i < capacity { out[i] = p }
        }
        return out
    }

    /// Number of distinct processes currently holding history (diagnostics / overhead display).
    public var trackedCount: Int { lock.lock(); defer { lock.unlock() }; return store.count }
}
