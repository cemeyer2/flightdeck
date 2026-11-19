import Foundation
// Follows macOS's privacy indicator in the unified log (CameraMicIndicatorLog.swift) with `/usr/bin/log stream`, but
// only while a camera or microphone is in use: CameraMicWatch starts it when a device listener reports use and stops
// it shortly after the last device goes idle. Nothing runs while the devices are idle.
//
// The indicator logs its change the moment an app starts capturing, which can be before the stream has connected
// (~0.2-1 s). So each start also runs one `log show` over the seconds since the device came on (a "backfill"), and the
// newer of the two answers wins. Measured on an M-series Mac with macOS 27.2: the stream itself used 0.00 s of CPU in
// 90 s (diagnosticd, which filters for it, +0.04 s); one backfill costs ~0.4 s of CPU, once per session.
//
// Threading: `start`/`stop` are called on the watch's queue, and `onActive` is delivered there. The pipe is read on a
// background thread; a generation number discards output from a stream or backfill that has since been stopped.

final class IndicatorLogStream: @unchecked Sendable {
    /// The indicator's active set and the time it was logged (nil if the line had no readable time). On `queue`.
    var onActive: ([IndicatorAttribution], Date?) -> Void = { _, _ in }
    private let queue: DispatchQueue
    private var process: Process?
    private var generation = 0
    private var restarts = 0
    /// Set when `/usr/bin/log` can't run at all, for the UI ("app names unavailable: …").
    private(set) var failure: String?

    init(queue: DispatchQueue) { self.queue = queue }

    var isRunning: Bool { process?.isRunning == true }

    /// Starts the stream (if not running) and a backfill from `since`. On `queue`.
    func start(since: Date) {
        guard process == nil else { return }
        generation += 1; restarts = 0
        launchStream(generation)
        backfill(from: since, generation)
    }

    /// Stops the stream. On `queue`.
    func stop() {
        generation += 1
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    private func launchStream(_ gen: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "ndjson", "--predicate", IndicatorLogParser.predicate]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        let lines = LineSplitter()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }   // EOF: the process ended
            for line in lines.feed(chunk) {
                guard let r = IndicatorLogParser.parse(ndjson: line) else { continue }
                self?.queue.async { if self?.generation == gen { self?.onActive(r.active, r.time) } }
            }
        }
        // If `log` dies while still wanted (logd restarted, say), try again a few times.
        p.terminationHandler = { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 5) {
                guard let self, self.generation == gen, self.process === p else { return }
                self.process = nil
                if self.restarts < 5 { self.restarts += 1; self.launchStream(gen) }
            }
        }
        do { try p.run(); process = p; failure = nil } catch {
            failure = "couldn't run /usr/bin/log: \(error.localizedDescription)"
        }
    }

    /// One `log show` since `from` (a few seconds back): the newest active set in that window, if any.
    private func backfill(from: Date, _ gen: Int) {
        let start = Int(from.timeIntervalSince1970.rounded(.down))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["show", "--style", "ndjson", "--start", "@\(start)", "--predicate", IndicatorLogParser.predicate]
            let out = Pipe()
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var newest: (time: Date?, active: [IndicatorAttribution])?
            for line in data.split(separator: 0x0A) {
                if let r = IndicatorLogParser.parse(ndjson: Data(line)) { newest = r }   // `log show` is oldest first
            }
            guard let newest else { return }
            self?.queue.async { if self?.generation == gen { self?.onActive(newest.active, newest.time) } }
        }
    }
}

/// Splits a byte stream into lines across chunk boundaries. Used only from the pipe's reader thread.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    /// A line longer than this with no newline is dropped, so a malformed stream can't grow the buffer without bound.
    static let maxLine = 1 << 20

    func feed(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var out: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            out.append(Data(buffer[buffer.startIndex..<nl]))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        if buffer.count > Self.maxLine { buffer.removeAll() }
        return out
    }
}
