import Foundation
import IOKit.ps

// Running networkQuality, keeping the history of results, and deciding when the opt-in schedule may run a test.
// Nothing here runs on its own: the app's InternetModel starts a test on a button press or when `schedule` says so.

/// One `networkQuality -c` run as a cancellable subprocess. The run takes ~15–20 s and moves real data (hundreds of
/// MB on a fast line), so it is never started implicitly. Completion is called once, on an arbitrary queue.
public final class SpeedTestRun: @unchecked Sendable {
    public static let tool = "/usr/bin/networkQuality"
    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: tool) }

    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false, timedOut = false

    public init() {}

    /// Starts the test. `timeout` bounds a stuck run (no network, unreachable config server): networkQuality is
    /// terminated and the run reports `.timedOut`.
    public func start(timeout: TimeInterval = 90, context: SpeedTestContext?, scheduled: Bool,
                      completion: @escaping @Sendable (Result<SpeedTestResult, SpeedTestError>) -> Void) {
        guard Self.isAvailable else { completion(.failure(.unavailable("networkQuality isn't available on this macOS version"))); return }
        process.executableURL = URL(fileURLWithPath: Self.tool)
        process.arguments = ["-c"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        do { try process.run() } catch { completion(.failure(.unavailable("couldn't start networkQuality: \(error.localizedDescription)"))); return }
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, p.isRunning else { return }
            self.lock.lock(); self.timedOut = true; self.lock.unlock()
            p.terminate()
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            // stderr is drained concurrently so neither pipe can fill up and stall the child.
            var errData = Data()
            let g = DispatchGroup(); g.enter()
            DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit(); g.wait()
            lock.lock(); let c = cancelled, t = timedOut; lock.unlock()
            if c { completion(.failure(.cancelled)); return }
            if t { completion(.failure(.timedOut)); return }
            do {
                var r = try SpeedTest.parse(data.isEmpty ? errData : data)
                r.context = context; r.scheduled = scheduled
                completion(.success(r))
            } catch let e as SpeedTestError {
                // A plain-text failure usually lands on stderr; report that rather than "no output".
                if case .notJSON(let s) = e, s.isEmpty, !errData.isEmpty {
                    completion(.failure(.notJSON(String(String(decoding: errData, as: UTF8.self).prefix(200)))))
                } else { completion(.failure(e)) }
            } catch { completion(.failure(.noMeasurements)) }
        }
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }
}

/// Saved results, newest last, as JSON next to the daily log (speedtests.json). Small: one entry per test.
public enum SpeedTestHistory {
    public static let retentionDays = 90
    public static let maxEntries = 3000

    public static func url(in dir: URL) -> URL { dir.appendingPathComponent("speedtests.json") }

    struct File: Codable { var version = 1; var results: [SpeedTestResult] }

    /// Unreadable or missing file → empty history (never fails the app).
    public static func load(from url: URL) -> [SpeedTestResult] {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: url), let f = try? d.decode(File.self, from: data) else { return [] }
        return f.results.sorted { $0.time < $1.time }
    }

    public static func save(_ results: [SpeedTestResult], to url: URL) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        guard let data = try? e.encode(File(results: results)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Appends and applies retention (by age, then by count).
    public static func appending(_ r: SpeedTestResult, to results: [SpeedTestResult], now: Date = Date()) -> [SpeedTestResult] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let kept = (results + [r]).filter { $0.time >= cutoff }.sorted { $0.time < $1.time }
        return Array(kept.suffix(maxEntries))
    }
}

/// When the opt-in schedule may run a test. Pure, so it is unit-tested; the app evaluates it about once a minute
/// while it runs (the schedule never wakes the Mac or runs when FlightDeck isn't running).
public enum SpeedTestSchedule {
    /// Hours between scheduled tests; 0 = off (the default).
    public static let choices = [0, 1, 3, 6]
    public static let defaultsKey = "speedTestScheduleHours"
    /// On battery, scheduled tests need at least this charge.
    public static let minBatteryPercent = 20.0

    public struct Conditions: Sendable {
        public var now: Date
        public var intervalHours: Int
        /// Last test finished or attempted (a failed attempt counts, so a broken network isn't retried every minute).
        public var lastRun: Date?
        public var onBattery: Bool
        public var batteryPercent: Double?
        /// NWPath: a hotspot / cellular / metered interface (`isExpensive`) or Low Data Mode (`isConstrained`).
        public var isExpensive: Bool
        public var isConstrained: Bool
        public var online: Bool
        public var demo: Bool
        public var running: Bool
        public init(now: Date, intervalHours: Int, lastRun: Date?, onBattery: Bool, batteryPercent: Double?, isExpensive: Bool,
                    isConstrained: Bool, online: Bool, demo: Bool = false, running: Bool = false) {
            self.now = now; self.intervalHours = intervalHours; self.lastRun = lastRun; self.onBattery = onBattery
            self.batteryPercent = batteryPercent; self.isExpensive = isExpensive; self.isConstrained = isConstrained
            self.online = online; self.demo = demo; self.running = running
        }
    }

    public enum Decision: Equatable, Sendable {
        case run
        case notDue(Date)
        /// Due, but conditions forbid it; the reason is shown in the UI.
        case skip(String)
        case off
    }

    public static func decide(_ c: Conditions) -> Decision {
        guard c.intervalHours > 0, !c.demo else { return .off }
        if let last = c.lastRun {
            let due = last.addingTimeInterval(Double(c.intervalHours) * 3600)
            // A clock set backwards makes `last` look in the future; treat that as due rather than waiting forever.
            if c.now < due && last <= c.now { return .notDue(due) }
        }
        if c.running { return .skip("a test is already running") }
        if !c.online { return .skip("offline") }
        if c.isExpensive { return .skip("on a hotspot or metered connection") }
        if c.isConstrained { return .skip("Low Data Mode is on") }
        if c.onBattery {
            guard let p = c.batteryPercent else { return .skip("on battery (charge unknown)") }
            if p < minBatteryPercent { return .skip("on battery at \(Int(p))% (needs \(Int(minBatteryPercent))%)") }
        }
        return .run
    }

    /// Power source and charge, read straight from IOKit (cheap) so the schedule doesn't depend on a snapshot.
    public static func powerState() -> (onBattery: Bool, percent: Double?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, nil) }
        let onBattery = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSBatteryPowerValue
        var pct: Double?
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                pct = Double(cur) / Double(max) * 100
            }
        }
        return (onBattery, pct)
    }
}
