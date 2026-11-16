import Foundation

/// Compact recent history for every process (not just the busiest), so any process can be inspected with
/// its past. Written on the sampling queue, read from the UI; internally locked.
public final class ProcessHistory: @unchecked Sendable {
    public struct Point: Sendable {
        public var cpu: Float, memory: Float, diskRead: Float, diskWrite: Float
        public var netIn: Float?, netOut: Float?
        public var gpu: Float?
    }
    public let capacity: Int
    private var tick = 0
    private var store: [ProcessIdentity: [(tick: Int, point: Point)]] = [:]
    private let lock = NSLock()

    public init(capacity: Int = 300) { self.capacity = capacity }

    public func record(_ procs: [ProcessSample]) {
        lock.lock(); defer { lock.unlock() }
        tick += 1
        for p in procs {
            let pt = Point(cpu: Float(p.cpu), memory: Float(p.memory), diskRead: Float(p.diskReadBps), diskWrite: Float(p.diskWriteBps),
                           netIn: p.network.map { Float($0.inBps) }, netOut: p.network.map { Float($0.outBps) },
                           gpu: p.gpu.map(Float.init))
            store[p.identity, default: []].append((tick, pt))
        }
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
    public func series(_ id: ProcessIdentity) -> [Point?] {
        lock.lock(); defer { lock.unlock() }
        var out = [Point?](repeating: nil, count: capacity)
        for (t, p) in store[id] ?? [] {
            let i = capacity - 1 - (tick - t)
            if i >= 0 && i < capacity { out[i] = p }
        }
        return out
    }

    public var trackedCount: Int { lock.lock(); defer { lock.unlock() }; return store.count }
}
