import Foundation

// Easter eggs. Each FlightDeck version gets its own, opened by typing the Konami code (↑ ↑ ↓ ↓ ← → ← → B A) in the main
// window. 1.5's is Turbulence: a one-button flying game whose terrain is this Mac's own recent history, CPU load as
// the mountains below and memory pressure as the clouds above, with the app behind each big peak named on it.
// Everything here is pure (no clock, no UI), so the app drives it with frame times and tests can drive it directly.

/// Recognises the Konami code in a stream of key presses. Any wrong key restarts the match (or starts a new one, if
/// that key is itself the code's first key).
public struct KonamiCode: Sendable {
    public enum Key: Sendable { case up, down, left, right, b, a, other }
    public static let sequence: [Key] = [.up, .up, .down, .down, .left, .right, .left, .right, .b, .a]
    private var matched = 0
    public init() {}

    /// Feeds one key; true when it completes the code.
    public mutating func feed(_ k: Key) -> Bool {
        if k == Self.sequence[matched] {
            matched += 1
        } else {
            // "↑ ↑ ↑" is still two ups toward the code, so an extra up keeps the match at two.
            matched = k == .up && matched == 2 ? 2 : (k == Self.sequence[0] ? 1 : 0)
        }
        guard matched == Self.sequence.count else { return false }
        matched = 0
        return true
    }
}

/// The course: one column per slice of history. Heights are fractions of the play area's height: `ground` rises from
/// the bottom, `ceiling` hangs from the top, and there is always at least `minGap` of open sky between them.
public struct TurbulenceCourse: Sendable {
    public struct Column: Sendable, Equatable {
        public var ground: Double
        public var ceiling: Double
        /// When this slice of history happened (nil for invented filler).
        public var time: Date?
        /// The busiest app, on the course's tallest peaks only.
        public var label: String?
        public init(ground: Double, ceiling: Double, time: Date? = nil, label: String? = nil) {
            self.ground = ground; self.ceiling = ceiling; self.time = time; self.label = label
        }
    }
    public var columns: [Column]
    /// Seconds of history per column (0 for an invented course).
    public var secondsPerColumn: Double

    public static let minGap = 0.34
    public static let maxColumns = 240
    /// Flat columns before the course starts, so the first seconds are a calm takeoff.
    public static let runway = 14

    public init(columns: [Column], secondsPerColumn: Double) {
        self.columns = columns.isEmpty ? Self.filler(60) : columns
        self.secondsPerColumn = columns.isEmpty ? 0 : secondsPerColumn
    }

    /// Builds the course from frames, oldest first, averaging them into at most `maxColumns` columns.
    public static func from(_ frames: [Snapshot]) -> TurbulenceCourse {
        let frames = frames.sorted { $0.time < $1.time }
        guard frames.count >= 2 else { return TurbulenceCourse(columns: [], secondsPerColumn: 0) }
        let per = max(1, Int((Double(frames.count) / Double(maxColumns)).rounded(.up)))
        var cpu: [Double] = [], mem: [Double] = [], times: [Date] = [], busiest: [(String, Double)?] = []
        var i = 0
        while i < frames.count {
            let slice = frames[i..<min(i + per, frames.count)]
            let c = slice.compactMap { $0.cpu.total.value }, m = slice.compactMap { $0.memory.pressure.value }
            cpu.append(c.isEmpty ? 0 : c.reduce(0, +) / Double(c.count))
            mem.append(m.isEmpty ? 0 : m.reduce(0, +) / Double(m.count))
            times.append(slice.first!.time)
            let top = slice.flatMap(\.processes).max { $0.cpu < $1.cpu }
            busiest.append(top.map { ($0.name, $0.cpu) })
            i += per
        }
        // A light 3-column average turns sample noise into hills rather than spikes.
        func smooth(_ v: [Double]) -> [Double] {
            v.indices.map { j in
                let lo = max(0, j - 1), hi = min(v.count - 1, j + 1)
                return v[lo...hi].reduce(0, +) / Double(hi - lo + 1)
            }
        }
        let g = smooth(cpu), m = smooth(mem)
        let ground = rampLimited(g.map { 0.06 + min(max($0, 0), 100) / 100 * 0.56 })
        let ceiling = rampLimited(m.map { 0.04 + min(max($0, 0), 100) / 100 * 0.32 })
        var cols: [Column] = g.indices.map { j in
            Column(ground: ground[j], ceiling: max(0.02, min(ceiling[j], 1 - minGap - ground[j])), time: times[j])
        }
        // Name the tallest peaks: a local maximum of at least 45% CPU, at least 10 columns from the last named one.
        var lastLabel = -100
        for j in cols.indices where g[j] >= 45 && j - lastLabel >= 10
            && g[j] >= g[max(0, j - 1)] && g[j] >= g[min(g.count - 1, j + 1)] {
            if let b = busiest[j] { cols[j].label = b.0; lastLabel = j }
        }
        let interval = frames.last!.time.timeIntervalSince(frames.first!.time) / Double(max(1, frames.count - 1))
        return TurbulenceCourse(columns: cols, secondsPerColumn: interval * Double(per))
    }

    /// The steepest a slope may be, per column: what the plane can climb at top speed (TurbulenceGame.maxClimb per
    /// second at its 11 columns/s), with a little to spare.
    public static let maxSlope = 0.075
    /// Columns that ease from the course's end back to its start when it loops.
    static let seam = 8

    /// Raises the foot of every rise and fall until no slope is steeper than `maxSlope`. Peaks keep their height; a
    /// spike becomes a mountain with climbable sides.
    public static func rampLimited(_ v: [Double]) -> [Double] {
        var r = v
        for j in r.indices.dropFirst() { r[j] = max(r[j], r[j - 1] - maxSlope) }
        for j in r.indices.dropLast().reversed() { r[j] = max(r[j], r[j + 1] - maxSlope) }
        return r
    }

    /// Gentle invented hills, for a Mac with no history yet.
    static func filler(_ n: Int) -> [Column] {
        (0..<n).map { j in
            let x = Double(j)
            return Column(ground: 0.14 + 0.12 * (1 + sin(x / 5)) + 0.06 * sin(x / 1.7), ceiling: 0.06 + 0.05 * (1 + cos(x / 7)))
        }
    }

    /// Ground and ceiling at position `x` (in columns), interpolated. Before 0 is the runway; past the end the course
    /// loops, easing from its last column back to its first over a few columns so the seam is never a cliff.
    public func at(_ x: Double) -> (ground: Double, ceiling: Double) {
        let runwayColumn = Column(ground: 0.06, ceiling: 0.04)
        if x < 0 {
            let first = columns[0], t = min(1, max(0, (x + 8) / 8))   // the last 8 runway columns ease into the course
            return (runwayColumn.ground + (first.ground - runwayColumn.ground) * t,
                    runwayColumn.ceiling + (first.ceiling - runwayColumn.ceiling) * t)
        }
        let n = Double(columns.count + Self.seam)   // easing columns after the last
        let p = x.truncatingRemainder(dividingBy: n)
        func col(_ k: Int) -> Column {
            if k < columns.count { return columns[k] }
            let a = columns[columns.count - 1], b = columns[0], t = Double(k - columns.count + 1) / Double(Self.seam + 1)
            return Column(ground: a.ground + (b.ground - a.ground) * t, ceiling: a.ceiling + (b.ceiling - a.ceiling) * t)
        }
        let k = Int(p), f = p - Double(k), a = col(k), b = col((k + 1) % Int(n))
        return (a.ground + (b.ground - a.ground) * f, a.ceiling + (b.ceiling - a.ceiling) * f)
    }

    /// The column at position `x` (looping), for its time and label; nil on the runway and the easing columns.
    public func column(at x: Double) -> Column? {
        guard x >= 0 else { return nil }
        let k = Int(x.truncatingRemainder(dividingBy: Double(columns.count + Self.seam)))
        return k < columns.count ? columns[k] : nil
    }
}

/// The game: a paper plane held at a fixed spot on screen while the course scrolls past. Holding climbs, letting go
/// sinks; touching the ground or the ceiling ends the flight.
public struct TurbulenceGame: Sendable {
    public enum Phase: Sendable, Equatable { case ready, flying, crashed }
    public let course: TurbulenceCourse
    public private(set) var phase: Phase = .ready
    /// Columns travelled since takeoff (negative while still on the runway).
    public private(set) var distance: Double
    /// Height of the plane's centre, as a fraction of the play area from the bottom.
    public private(set) var y = 0.45
    public private(set) var vy = 0.0
    public private(set) var elapsed = 0.0

    /// Where the plane sits on screen, in columns from the left edge, and how many columns are visible.
    public static let planeColumn = 9.0
    public static let visibleColumns = 42.0
    /// The plane's half-height (fraction of the play area) and half-length (columns), for collisions.
    public static let radius = 0.022
    public static let halfLength = 0.6
    /// Fastest climb or dive, in play-area heights per second.
    public static let maxClimb = 1.0

    public init(course: TurbulenceCourse) {
        self.course = course
        distance = -Double(TurbulenceCourse.runway) - Self.planeColumn
    }

    /// The course position under the plane.
    public var planeX: Double { distance + Self.planeColumn }
    /// Columns per second: a gentle start, slowly speeding up over the first two minutes.
    public var speed: Double { 5 + min(elapsed, 120) * 0.05 }
    /// Columns of real course flown (the runway doesn't count).
    public var score: Int { max(0, Int(planeX)) }
    /// How much of the Mac's history that is, in seconds (0 for an invented course).
    public var historyFlown: Double { Double(score) * course.secondsPerColumn }

    public mutating func start() {
        guard phase != .flying else { return }
        if phase == .crashed { self = TurbulenceGame(course: course) }
        phase = .flying
    }

    /// Advances by `dt` seconds (clamped, so a stalled frame can't teleport the plane into a mountain).
    public mutating func step(_ dt: Double, climbing: Bool) {
        guard phase == .flying else { return }
        let dt = min(max(dt, 0), 1.0 / 20)
        elapsed += dt
        vy += (climbing ? 3.0 : -2.0) * dt
        vy = min(max(vy, -Self.maxClimb), Self.maxClimb)
        y += vy * dt
        distance += speed * dt
        if crashed() { phase = .crashed; vy = 0 }
    }

    /// True when the plane (nose, middle or tail) touches the ground or the ceiling.
    func crashed() -> Bool {
        for dx in [-Self.halfLength, 0, Self.halfLength] {
            let h = course.at(planeX + dx)
            if y - Self.radius <= h.ground || y + Self.radius >= 1 - h.ceiling { return true }
        }
        return false
    }
}
