// State behind the Console destination: runs `log show` queries and the optional live tail (`log stream`) off the main
// thread with FlightDeckCore's LogReader/LogAggregator, and publishes immutable LogSummary copies. Owned by ConsoleView
// as a @StateObject, so leaving the destination discards results and stops all work.
import SwiftUI
import FlightDeckCore

@MainActor
final class ConsoleModel: ObservableObject {
    /// Time windows offered for a query; the raw value is seconds.
    enum Span: Int, CaseIterable, Identifiable {
        case m5 = 300, h1 = 3600, h24 = 86_400
        var id: Int { rawValue }
        var title: String { switch self { case .m5: "5 min"; case .h1: "1 hour"; case .h24: "24 hours" } }
    }
    /// Sparklines have this many slots; the aggregator's bucket width is chosen to match.
    static let sparkSlots = 48
    /// Live tail: 10 s buckets, sparklines over the last 5 minutes.
    static let tailBucket: TimeInterval = 10, tailSpan: TimeInterval = 300

    @Published var span: Span = .h1
    @Published private(set) var summary: LogSummary?
    /// The [from, to] the summary was asked for (sparklines are drawn over it).
    @Published private(set) var range: (from: Date, to: Date)?
    @Published private(set) var loading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var outcome: LogReader.Outcome?

    /// Live tail: what the user asked for, and whether `log stream` is actually running right now (it is paused while
    /// no FlightDeck window is visible).
    @Published private(set) var tailWanted = false
    @Published private(set) var tailRunning = false
    @Published private(set) var tail: LogSummary?
    @Published private(set) var tailError: String?

    // LogReader is thread-safe, so the readers can also be cancelled from deinit (a safety net behind `stopAll`).
    nonisolated(unsafe) private var reader: LogReader?
    private var generation = 0
    nonisolated(unsafe) private var tailReader: LogReader?
    private var tailBuffer: TailBuffer?
    private var tailTimer: Timer?

    deinit { reader?.cancel(); tailReader?.cancel() }

    // MARK: Query

    /// Starts a query for the current span, cancelling any running one. Results appear chunk by chunk.
    func load() {
        reader?.cancel()
        generation += 1
        let gen = generation, window = TimeInterval(span.rawValue), now = Date()
        let r = LogReader(); reader = r
        loading = true; progress = 0; outcome = nil; summary = nil
        range = (now.addingTimeInterval(-window), now)
        let bucket = window / Double(Self.sparkSlots)
        // Results are handed back through `owner` (captured once, outside the concurrent closures); `generation`
        // makes a superseded query's late results harmless.
        let owner = WeakModel(self)
        Task.detached(priority: .utility) {
            // The aggregator lives only on this task's thread; the main actor only ever sees LogSummary copies.
            let agg = LogAggregator(bucketWidth: bucket)
            let result = r.show(window: window, now: now, into: agg) { fraction in
                let s = agg.summary()
                Task { @MainActor in
                    guard let m = owner.model, m.generation == gen else { return }
                    m.progress = fraction; m.summary = s
                }
            }
            let final = agg.summary()
            await MainActor.run {
                guard let m = owner.model, m.generation == gen else { return }
                m.summary = final; m.outcome = result; m.loading = false; m.reader = nil
            }
        }
    }

    /// Stops the running query; what was read so far stays on screen.
    func cancel() { reader?.cancel() }

    // MARK: Live tail

    func setTail(_ on: Bool) {
        tailWanted = on
        if on {
            tail = nil; tailError = nil
            tailBuffer = TailBuffer(bucketWidth: Self.tailBucket)
            // The 1 s timer publishes what arrived and pauses/resumes `log stream` with window visibility. It only
            // exists while live tail is on.
            tailTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { t.invalidate(); return }   // model gone: stop the timer too
                    self.tick()
                }
            }
            tick()
        } else {
            tailTimer?.invalidate(); tailTimer = nil
            stopStream()
            tailBuffer = nil
        }
    }

    /// Called when the view disappears: no work continues for a screen nobody can see.
    func stopAll() { cancel(); setTail(false) }

    private func tick() {
        guard tailWanted, let buf = tailBuffer else { return }
        let visible = Self.anyWindowVisible()
        if visible && !tailRunning { startStream(buf) } else if !visible && tailRunning { stopStream() }
        if let s = buf.summaryIfChanged() { tail = s }
    }

    private func startStream(_ buf: TailBuffer) {
        let r = LogReader(); tailReader = r; tailRunning = true
        let owner = WeakModel(self)
        Task.detached(priority: .utility) {
            let result = r.stream { buf.add($0) }
            await MainActor.run {
                guard let m = owner.model, m.tailReader === r else { return }
                m.tailRunning = false; m.tailReader = nil
                if case .failed(let msg) = result { m.tailError = msg; m.setTail(false) }
            }
        }
    }

    private func stopStream() { tailReader?.cancel(); tailReader = nil; tailRunning = false }

    /// Same test as Engine's visibility tracking: some FlightDeck window (not the menu bar item) is on screen.
    static func anyWindowVisible() -> Bool {
        !NSApp.isHidden && NSApp.windows.contains { w in
            w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible) && !String(describing: type(of: w)).contains("StatusBar")
        }
    }
}

/// Entries from `log stream`, added on the reader's thread and summarised on the main actor; guarded by a lock.
/// Keeps at most 5,000 raw entries (counts still cover everything since the tail started).
final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let agg: LogAggregator
    private var changed = false
    init(bucketWidth: TimeInterval) { agg = LogAggregator(bucketWidth: bucketWidth, maxEntries: 5_000) }
    func add(_ e: LogEntry) { lock.lock(); agg.add(e); changed = true; lock.unlock() }
    /// A fresh summary, or nil if nothing arrived since the last call (so a quiet log doesn't re-render the view).
    func summaryIfChanged() -> LogSummary? {
        lock.lock(); defer { lock.unlock() }
        guard changed else { return nil }
        changed = false
        return agg.summary()
    }
}

/// A weak reference to the model that background tasks can carry; it is only dereferenced on the main actor.
final class WeakModel: @unchecked Sendable {
    weak var model: ConsoleModel?
    init(_ m: ConsoleModel) { model = m }
}
