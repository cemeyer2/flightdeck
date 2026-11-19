import Foundation
// Theil–Sen line fit with Sen's confidence interval for the slope. Battery health is read in 1% steps (or wobbles by
// about ±1% day to day with temperature and recent use) and has occasional recalibration jumps, so an ordinary
// least-squares line is pulled around by a few odd days. Theil–Sen takes the median of all pairwise slopes instead:
// it tolerates up to ~29% outliers and handles stepped data without any smoothing parameter to tune.

public struct RobustLine: Sendable, Equatable {
    /// y = intercept + slope × x.
    public var slope: Double
    public var intercept: Double
    /// Sen's (1968) distribution-free confidence interval for the slope at `confidence`; nil when there are too few
    /// points for one (the rank bounds fall outside the pairwise slopes).
    public var slopeLow: Double?
    public var slopeHigh: Double?
    /// The median x and the fitted y there: the band's lines pivot about this point (the fit is best determined in
    /// the middle of the data, so the range widens away from it, as it should).
    public var pivotX: Double
    public var pivotY: Double
    public var count: Int

    public func y(_ x: Double) -> Double { intercept + slope * x }
    /// The y of a band edge at x (slope `s` through the pivot).
    public func y(_ x: Double, slope s: Double) -> Double { pivotY + s * (x - pivotX) }
    /// The x where the line (or a band edge with slope `s`) reaches `target`; nil if it is flat.
    public func x(reaching target: Double, slope s: Double? = nil) -> Double? {
        let m = s ?? slope
        guard m != 0 else { return nil }
        return pivotX + (target - pivotY) / m
    }
}

public enum TheilSen {
    static func median(_ v: [Double]) -> Double {
        let s = v.sorted(), n = s.count
        guard n > 0 else { return .nan }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Fits the points. Pairs with equal x carry no slope and are skipped. O(n²) pairs, so callers keep n to a few
    /// hundred (`BatteryForecast` thins long histories to weekly medians). nil with fewer than 2 distinct x.
    /// `z` = 1.96 gives a 95% interval.
    public static func fit(_ pts: [(x: Double, y: Double)], z: Double = 1.96) -> RobustLine? {
        let n = pts.count
        guard n >= 2 else { return nil }
        var slopes: [Double] = []
        slopes.reserveCapacity(n * (n - 1) / 2)
        for i in 0..<n { for j in (i + 1)..<n where pts[j].x != pts[i].x { slopes.append((pts[j].y - pts[i].y) / (pts[j].x - pts[i].x)) } }
        guard !slopes.isEmpty else { return nil }
        slopes.sort()
        let m = slopes.count
        let slope = m % 2 == 1 ? slopes[m / 2] : (slopes[m / 2 - 1] + slopes[m / 2]) / 2
        let intercept = median(pts.map { $0.y - slope * $0.x })
        let px = median(pts.map(\.x))

        // Sen's interval: with Kendall's S variance Var(S) = [n(n−1)(2n+5) − Σ t(t−1)(2t+5)] / 18, where t runs over
        // groups of tied y values (stepped 1% readings produce many ties, which shrink the variance), the bounds are
        // the order statistics at (N − C)/2 and (N + C)/2 + 1 of the N sorted slopes, with C = z·√Var(S).
        let ties = Dictionary(grouping: pts.map(\.y), by: { $0 }).values.map { Double($0.count) }.filter { $0 > 1 }
        let dn = Double(n)
        let variance = (dn * (dn - 1) * (2 * dn + 5) - ties.reduce(0) { $0 + $1 * ($1 - 1) * (2 * $1 + 5) }) / 18
        let c = z * variance.squareRoot()
        let lo = Int(((Double(m) - c) / 2).rounded(.down)), hi = Int(((Double(m) + c) / 2).rounded(.up))
        // Ranks are 1-based in the formula; indexes here are 0-based.
        let low = lo >= 1 && lo <= m ? slopes[lo - 1] : nil
        let high = hi >= 1 && hi < m ? slopes[hi] : nil
        return RobustLine(slope: slope, intercept: intercept, slopeLow: low, slopeHigh: high,
                          pivotX: px, pivotY: intercept + slope * px, count: n)
    }
}
