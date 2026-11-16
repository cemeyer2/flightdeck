// Prepares the daily log for the Trends view: one slot per calendar day of the chosen range (nil where FlightDeck
// didn't run), the update markers, top apps and baselines. Built off the main thread when the view loads or the
// range changes, so rendering only reads finished arrays.
import Foundation
import FlightDeckCore

/// Immutable; the view compares instances by identity (`generation`) to skip needless re-renders.
final class TrendsData: @unchecked Sendable {
    let generation: Int
    let rangeDays: Int
    /// One per day of the range, oldest first, ending today.
    let slots: [DayRecord?]
    let labels: [String]
    /// Every update in the whole log (newest first), and the slot of those inside the range.
    let updates: [UpdateEvent]
    let markerSlot: [String: Int]
    /// Apps ranked by CPU time over the range.
    let topApps: [TopApp]
    let baselines: [AppBaseline]
    let charge: ChargeStatus
    /// Days with any data in the whole log.
    let recordedDays: Int
    let minBaselineDays: Int
    /// All days (for the before/after comparison, which may reach outside the range).
    let allDays: [DayRecord]

    struct TopApp: Identifiable {
        var id: String; var name: String; var cpuSeconds: Double; var energyWh: Double?; var peakMemory: UInt64
        var version: String?
        /// CPU seconds per slot (nil = not recorded that day).
        var daily: [Double?]
    }

    init(history h: DailyLog.History, rangeDays: Int, generation: Int, now: Date = Date(), calendar: Calendar = .current) {
        self.generation = generation; self.rangeDays = rangeDays
        let today = calendar.startOfDay(for: now)
        let byStart = Dictionary(h.days.map { ($0.start, $0) }, uniquingKeysWith: { _, b in b })
        let starts = (0..<rangeDays).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        slots = starts.map { byStart[$0] }
        let df = DateFormatter(); df.setLocalizedDateFormatFromTemplate("EEE d MMM")
        labels = starts.map { df.string(from: $0) }
        let ups = Trends.updates(h.days)
        updates = ups.reversed()
        var ms: [String: Int] = [:]
        for u in ups { if let i = starts.firstIndex(of: u.date) { ms[u.id] = i } }
        markerSlot = ms
        // Top apps over the range: totals and a per-day CPU series.
        var acc: [String: TopApp] = [:]
        for (i, d) in slots.enumerated() {
            for a in d?.apps ?? [] {
                var t = acc[a.id] ?? TopApp(id: a.id, name: a.name, cpuSeconds: 0, energyWh: nil, peakMemory: 0, version: nil, daily: Array(repeating: nil, count: rangeDays))
                t.cpuSeconds += a.cpuSeconds
                if let e = a.energyWh { t.energyWh = (t.energyWh ?? 0) + e }
                t.peakMemory = max(t.peakMemory, a.peakMemory)
                t.version = a.version ?? t.version
                t.daily[i] = a.cpuSeconds
                acc[a.id] = t
            }
        }
        topApps = Array(acc.values.sorted { $0.cpuSeconds > $1.cpuSeconds }.prefix(10))
        baselines = h.baselines.values.sorted { $0.memory > $1.memory }
        charge = h.charge
        recordedDays = h.days.filter { $0.observedSeconds > 0 }.count
        minBaselineDays = h.minBaselineDays
        allDays = h.days
    }

    /// `f` per slot.
    func series(_ f: (DayRecord) -> Double?) -> [Double?] { slots.map { $0.flatMap(f) } }
    var markers: [Int] { Array(markerSlot.values) }
}
