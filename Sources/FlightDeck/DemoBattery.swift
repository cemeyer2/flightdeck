// Demo mode's battery history: 400 invented days for DemoCharging's battery (93% health and 214 cycles today), so the
// Battery health panel's forecast, band and wear factors can be shown and screenshotted. Nothing comes from this Mac.
// The values are deterministic (a seeded generator), and shaped like real gauge data: about 2.6% health lost a year
// with ±0.8% day-to-day wobble, a few recalibration outliers, days off, the first 12 days marked as if seeded from
// macOS's power log, and a usage pattern (long desk sessions at 100%, warm afternoons) that lights up two wear tips.
import Foundation
import FlightDeckCore

@MainActor
enum DemoBattery {
    static let days = 400

    /// A small linear congruential generator, so every render draws the same invented history.
    struct Rand { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

    static func history(now: Date = Date(), calendar: Calendar = .current) -> [BatteryDay] {
        var rng = Rand(s: 0xBA77)
        let today = calendar.startOfDay(for: now)
        var out: [BatteryDay] = []
        for k in stride(from: days - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -k, to: today) else { continue }
            let age = Double(days - 1 - k)                      // days since the history starts
            if k > 0, rng.next() < 0.12 { continue }            // days the demo Mac wasn't used
            let trend = 93 + 2.6 * Double(k) / 365              // ends at 93% today
            var health = trend + (rng.next() - 0.5) * 1.6
            if rng.next() < 0.015 { health += 3 + rng.next() * 2 }   // a gauge recalibration outlier
            let cycles = Int((214 * age / Double(days - 1)).rounded())
            let c = calendar.dateComponents([.year, .month, .day], from: start)
            let key = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            let seeded = age < 12
            out.append(BatteryDay(day: key, start: start, health: health, cycles: cycles, wear: seeded ? nil : wear(&rng),
                                  source: seeded ? .macOS : .demo))
        }
        return out
    }

    /// One invented day: ~9 h observed, ~6 h plugged in (mostly sitting at 100%), warm afternoons, a deep discharge
    /// now and then, and a charge hold on a few days.
    static func wear(_ rng: inout Rand) -> BatteryWearDay {
        var w = BatteryWearDay()
        w.observedSeconds = (7 + rng.next() * 4) * 3600
        w.pluggedSeconds = w.observedSeconds * (0.55 + rng.next() * 0.2)
        w.pluggedHighSeconds = w.pluggedSeconds * (0.62 + rng.next() * 0.2)
        w.heldSeconds = rng.next() < 0.15 ? w.pluggedSeconds * 0.3 : 0
        w.tempSeconds = w.observedSeconds
        let avg = 30.5 + rng.next() * 3
        w.tempSum = avg * w.tempSeconds
        w.tempMax = avg + 4 + rng.next() * 5
        w.above35Seconds = w.tempSeconds * (0.08 + rng.next() * 0.1)
        w.above40Seconds = (w.tempMax ?? 0) > 40 ? 600 + rng.next() * 1200 : 0
        w.dischargesBelow20 = rng.next() < 0.18 ? 1 : 0
        w.dischargesBelow10 = w.dischargesBelow20 > 0 && rng.next() < 0.25 ? 1 : 0
        w.minPercent = w.dischargesBelow20 > 0 ? 8 + rng.next() * 11 : 25 + rng.next() * 30
        return w
    }

    /// The gauge's lifetime figures for the demo battery.
    static func lifetime(now: Date = Date()) -> BatteryLifetime {
        BatteryLifetime(maxTemp: 46, minTemp: 4, operatingHours: 9_850, asOf: now)
    }

    static func report(battery: BatteryInfo?, facts: BatteryFacts?, now: Date = Date()) -> BatteryReport {
        BatteryReport(battery: battery, facts: facts, condition: "Good", history: history(now: now), lifetime: lifetime(now: now))
    }
}
