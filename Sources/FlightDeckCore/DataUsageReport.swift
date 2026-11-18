import Foundation

// The Internet view's data-usage table: per app, today / 7 days / 30 days, a 30-day sparkline, and a flag when
// today is far above that app's own usual day. Built from daily records on demand (O(days × apps)), never per sample.

public struct DataUsageRow: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var today: UInt64
    public var week: UInt64
    public var month: UInt64
    public var monthIn: UInt64
    public var monthOut: UInt64
    /// One slot per day, oldest first, ending today: nil = that day wasn't counted (FlightDeck not running).
    public var daily: [Double?]
    /// Set when today is unusual for this app, e.g. "2.10 GB today; usually about 180.0 MB a day" (decimal units, as
    /// providers count data).
    public var unusual: String?
}

public struct DataUsageReport: Sendable {
    public var rows: [DataUsageRow]
    public var todayTotal: UInt64?
    public var weekTotal: UInt64
    public var monthTotal: UInt64
    /// Days in the 30-day window that have any count.
    public var countedDays: Int
    /// When today's counting started, and how long it has counted.
    public var todaySince: Date?
    public var todaySeconds: Double
    /// Axis labels for `daily` ("3 Nov").
    public var labels: [String]

    /// `days` oldest first, ending with today (as `DailyLog.history()` returns them). `now` defines "today".
    public static func build(days: [DayRecord], now: Date = Date(), calendar: Calendar = .current, slots: Int = 30) -> DataUsageReport {
        let today = calendar.startOfDay(for: now)
        let starts: [Date] = (0..<slots).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let byStart = Dictionary(days.map { ($0.start, $0) }, uniquingKeysWith: { _, b in b })
        let usage: [DataUsageDay?] = starts.map { byStart[$0]?.dataUsage }
        let n = usage.count
        var rows: [String: DataUsageRow] = [:]
        for (i, u) in usage.enumerated() {
            guard let u else { continue }
            for a in u.apps {
                var r = rows[a.id] ?? DataUsageRow(id: a.id, name: a.name, today: 0, week: 0, month: 0, monthIn: 0, monthOut: 0,
                                                   daily: usage.map { $0 == nil ? nil : 0 }, unusual: nil)
                r.name = a.name
                r.month += a.total; r.monthIn += a.bytesIn; r.monthOut += a.bytesOut
                if i >= n - 7 { r.week += a.total }
                if i == n - 1 { r.today += a.total }
                r.daily[i] = Double(a.total)
                rows[a.id] = r
            }
        }
        for (id, r) in rows {
            // Earlier counted days only (today is the one being judged); an app absent on a counted day used ~0.
            let history = r.daily.dropLast().compactMap { $0 }
            rows[id]?.unusual = unusual(today: r.today, history: history)
        }
        let fmt = DateFormatter(); fmt.calendar = calendar; fmt.timeZone = calendar.timeZone; fmt.setLocalizedDateFormatFromTemplate("d MMM")
        let todayUsage = usage.last ?? nil
        return DataUsageReport(
            rows: rows.values.sorted { $0.month != $1.month ? $0.month > $1.month : $0.id < $1.id },
            todayTotal: todayUsage?.total,
            weekTotal: usage.suffix(7).compactMap { $0?.total }.reduce(0, +),
            monthTotal: usage.compactMap { $0?.total }.reduce(0, +),
            countedDays: usage.compactMap { $0 }.count,
            todaySince: todayUsage?.firstCounted, todaySeconds: todayUsage?.countedSeconds ?? 0,
            labels: starts.map { fmt.string(from: $0) })
    }

    /// Minimum earlier counted days before an app can be called unusual.
    public static let minHistoryDays = 5

    /// Today is unusual when it is at least 100 MB and above both 3× the app's median day and the median + 200 MB
    /// (so a usually tiny app needs a real jump, and a usually heavy app needs a large multiple). Median, not mean,
    /// so one earlier heavy day doesn't hide the next one. nil when there isn't enough history or nothing stands out.
    public static func unusual(today: UInt64, history: [Double]) -> String? {
        guard history.count >= minHistoryDays, today >= 100_000_000 else { return nil }
        let s = history.sorted()
        let median = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        let threshold = max(median * 3, median + 200_000_000)
        guard Double(today) >= threshold else { return nil }
        return "\(Fmt.storage(today)) today; usually about \(Fmt.storage(median)) a day"
    }
}
