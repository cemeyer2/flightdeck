import Foundation

// Quick, self-contained benchmarks for the Tools view. They are run only on explicit user request (each takes 2-6 s
// of full load), on a detached userInitiated task so the UI stays responsive.
/// One benchmark outcome. `score` is in `unit`; a failed run has score 0, empty unit and detail "failed".
public struct BenchmarkResult: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var score: Double
    public var unit: String
    public var detail: String
}

public enum Benchmarks {
    /// Benchmark identifiers, which are also the display names; `run` dispatches on these exact strings.
    public static let names = ["CPU single-core", "CPU multi-core", "Memory bandwidth", "Disk sequential write", "Disk sequential read"]

    /// Integer + floating work: returns iterations per second for one thread.
    /// A xorshift64 PRNG step (integer ALU) plus a sqrt (FP unit) per iteration, in batches of 200,000 so the clock is
    /// checked rarely. The rate is divided by the nominal duration; the last batch's small overshoot is ignored.
    static func cpuKernel(seconds: Double) -> Double {
        let end = Date().addingTimeInterval(seconds)
        var iters = 0.0
        var x: UInt64 = 88172645463325252, acc = 0.0
        while Date() < end {
            for _ in 0..<200_000 {
                x ^= x << 13; x ^= x >> 7; x ^= x << 17
                acc += sqrt(Double(x & 0xffff))
            }
            iters += 200_000
        }
        // Never true (acc is a sum of non-negative roots), but it makes `acc` observable so the optimizer can't delete the loop.
        if acc == -1 { print(acc) }
        return iters / seconds
    }

    /// Runs one benchmark by name and returns its result; unknown names or I/O failures return the "failed" result.
    public static func run(_ name: String) async -> BenchmarkResult {
        await Task.detached(priority: .userInitiated) { () -> BenchmarkResult in
            switch name {
            case "CPU single-core":
                let r = cpuKernel(seconds: 3)
                return .init(name: name, score: r / 1e6, unit: "M ops/s", detail: "xorshift + sqrt, 1 thread, 3 s")
            case "CPU multi-core":
                // One kernel per active core (P and E cores alike), summed. Each child task blocks its thread for 3 s, which is
                // intended here: the cooperative pool is sized to the core count, so every core gets one.
                let n = ProcessInfo.processInfo.activeProcessorCount
                let total = await withTaskGroup(of: Double.self) { g -> Double in
                    for _ in 0..<n { g.addTask { cpuKernel(seconds: 3) } }
                    return await g.reduce(0, +)
                }
                return .init(name: name, score: total / 1e6, unit: "M ops/s", detail: "\(n) threads, 3 s")
            case "Memory bandwidth":
                // 256 MB buffers, far larger than any cache level, so memcpy is bound by DRAM. Both buffers are written first so
                // their pages are faulted in before timing. The score counts bytes copied; actual memory traffic is twice that
                // (read + write).
                let size = 256 << 20
                let a = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64)
                let b = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64)
                defer { a.deallocate(); b.deallocate() }
                memset(a, 1, size); memset(b, 0, size)
                let t0 = Date(); var copied = 0
                while Date().timeIntervalSince(t0) < 2 { memcpy(b, a, size); copied += size }
                return .init(name: name, score: Double(copied) / Date().timeIntervalSince(t0) / 1e9, unit: "GB/s", detail: "memcpy 256 MB blocks")
            case "Disk sequential write", "Disk sequential read":
                // 1 GB written in 8 MB chunks to a temp file with F_NOCACHE, which bypasses the unified buffer cache so the
                // drive, not RAM, is measured. The write time includes the final synchronize (fsync). The read test writes
                // the file first (untimed) and both tests delete it afterwards, so no 1 GB file is left behind. A write
                // error (e.g. disk full) fails the test instead of crashing: `write(contentsOf:)` throws, `write(_:)` raises.
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("flightdeck-bench.bin")
                let chunk = Data(count: 8 << 20), total = 1 << 30
                if name.hasSuffix("write") || !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    guard let h = try? FileHandle(forWritingTo: url) else { break }
                    _ = fcntl(h.fileDescriptor, F_NOCACHE, 1)
                    let t0 = Date(); var w = 0
                    var failure: Error?
                    while w < total { do { try h.write(contentsOf: chunk); w += chunk.count } catch { failure = error; break } }
                    try? h.synchronize(); try? h.close()
                    if let failure {
                        try? FileManager.default.removeItem(at: url)
                        return .init(name: name, score: 0, unit: "", detail: "failed: \(failure.localizedDescription)")
                    }
                    if name.hasSuffix("write") {
                        let secs = Date().timeIntervalSince(t0)
                        try? FileManager.default.removeItem(at: url)
                        return .init(name: name, score: Double(w) / secs / 1e6, unit: "MB/s", detail: "1 GB, 8 MB blocks, uncached")
                    }
                }
                guard let h = try? FileHandle(forReadingFrom: url) else { break }
                _ = fcntl(h.fileDescriptor, F_NOCACHE, 1)
                let t0 = Date(); var r = 0
                while let d = try? h.read(upToCount: 8 << 20), !d.isEmpty { r += d.count }
                try? h.close(); try? FileManager.default.removeItem(at: url)
                return .init(name: name, score: Double(r) / Date().timeIntervalSince(t0) / 1e6, unit: "MB/s", detail: "1 GB, 8 MB blocks, uncached")
            default: break
            }
            return .init(name: name, score: 0, unit: "", detail: "failed")
        }.value
    }
}
