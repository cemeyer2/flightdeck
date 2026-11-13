import Foundation

public struct BenchmarkResult: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var score: Double
    public var unit: String
    public var detail: String
}

public enum Benchmarks {
    public static let names = ["CPU single-core", "CPU multi-core", "Memory bandwidth", "Disk sequential write", "Disk sequential read"]

    /// Integer + floating work: returns iterations per second for one thread.
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
        if acc == -1 { print(acc) }
        return iters / seconds
    }

    public static func run(_ name: String) async -> BenchmarkResult {
        await Task.detached(priority: .userInitiated) { () -> BenchmarkResult in
            switch name {
            case "CPU single-core":
                let r = cpuKernel(seconds: 3)
                return .init(name: name, score: r / 1e6, unit: "M ops/s", detail: "xorshift + sqrt, 1 thread, 3 s")
            case "CPU multi-core":
                let n = ProcessInfo.processInfo.activeProcessorCount
                let total = await withTaskGroup(of: Double.self) { g -> Double in
                    for _ in 0..<n { g.addTask { cpuKernel(seconds: 3) } }
                    return await g.reduce(0, +)
                }
                return .init(name: name, score: total / 1e6, unit: "M ops/s", detail: "\(n) threads, 3 s")
            case "Memory bandwidth":
                let size = 256 << 20
                let a = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64)
                let b = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64)
                defer { a.deallocate(); b.deallocate() }
                memset(a, 1, size); memset(b, 0, size)
                let t0 = Date(); var copied = 0
                while Date().timeIntervalSince(t0) < 2 { memcpy(b, a, size); copied += size }
                return .init(name: name, score: Double(copied) / Date().timeIntervalSince(t0) / 1e9, unit: "GB/s", detail: "memcpy 256 MB blocks")
            case "Disk sequential write", "Disk sequential read":
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("meterline-bench.bin")
                let chunk = Data(count: 8 << 20), total = 1 << 30
                if name.hasSuffix("write") || !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    guard let h = try? FileHandle(forWritingTo: url) else { break }
                    _ = fcntl(h.fileDescriptor, F_NOCACHE, 1)
                    let t0 = Date(); var w = 0
                    while w < total { h.write(chunk); w += chunk.count }
                    try? h.synchronize(); try? h.close()
                    if name.hasSuffix("write") {
                        return .init(name: name, score: Double(w) / Date().timeIntervalSince(t0) / 1e6, unit: "MB/s", detail: "1 GB, 8 MB blocks, uncached")
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
