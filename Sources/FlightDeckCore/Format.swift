import Foundation
// Shared number formatting for the UI, CLI, reports and finding text, so every surface shows the same units.

/// Formatting helpers. All take already-measured values; unavailable values are handled by callers
/// (see `Measured.formatted`), so nothing here ever prints a placeholder zero.
public enum Fmt {
    /// Binary (1024-based) byte sizes: "512 B", "1.5 GB". Whole bytes have no decimal.
    public static func bytes(_ b: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = b, i = 0
        // `abs` so negative deltas (e.g. "-2.1 GB" of free space) scale the same way as positive ones.
        while abs(v) >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? String(format: "%.0f %@", v, units[i]) : String(format: "%.1f %@", v, units[i])
    }
    public static func bytes(_ b: UInt64) -> String { bytes(Double(b)) }
    /// Disk and file sizes in decimal units (1 GB = 10⁹ bytes), as Finder and Disk Utility show them. Memory stays in
    /// `bytes` (binary units, as Activity Monitor shows it), so the same drive reads the same here as in Finder.
    public static func storage(_ b: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = b, i = 0
        while abs(v) >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? String(format: "%.0f %@", v, units[i]) : String(format: i >= 3 ? "%.2f %@" : "%.1f %@", v, units[i])
    }
    public static func storage(_ b: UInt64) -> String { storage(Double(b)) }

    /// A temperature (given in °C, as every sensor reports it) in the user's chosen unit, e.g. "52 °C" or "126 °F".
    public static func temp(_ celsius: Double, digits: Int = 0) -> String { tempNumber(celsius, digits: digits) + " " + TemperatureUnit.current.symbol }
    /// Just the number, in the chosen unit, for readouts that show the unit separately.
    public static func tempNumber(_ celsius: Double, digits: Int = 0) -> String { String(format: "%.\(digits)f", TemperatureUnit.current.convert(celsius)) }
    /// A byte rate (bytes/s), e.g. "12.3 MB/s".
    public static func rate(_ bps: Double) -> String { bytes(bps) + "/s" }
    /// A byte rate (bytes/s) shown in decimal bits per second ("Mbps"), as network speeds are usually quoted.
    public static func bits(_ bps: Double) -> String {
        let units = ["bps", "Kbps", "Mbps", "Gbps"]
        var v = bps * 8, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return String(format: "%.1f %@", v, units[i])
    }
    /// A percentage that is already in 0..100 (or above, for "% of one core"), e.g. "45.2%".
    public static func pct(_ p: Double) -> String { String(format: "%.1f%%", p) }
    /// Seconds as "h:mm:ss", or "Nd Nh Nm" once it passes a day. Fractions of a second are truncated.
    public static func duration(_ s: TimeInterval) -> String {
        let t = Int(s); let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60, sec = t % 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        return String(format: "%d:%02d:%02d", h, m, sec)
    }
}

/// Settings › Temperature unit. Everything is measured and stored in °C (recordings, CSV and Prometheus exports stay in
/// °C); only what people read is converted. Defaults to the Mac's region: °F where the US measurement system is used.
public enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case celsius, fahrenheit
    public var id: String { rawValue }
    public static let defaultsKey = "temperatureUnit"
    public static var current: TemperatureUnit {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:))
            ?? (Locale.current.measurementSystem == .us ? .fahrenheit : .celsius)
    }
    public var symbol: String { self == .celsius ? "°C" : "°F" }
    public var title: String { self == .celsius ? "Celsius (°C)" : "Fahrenheit (°F)" }
    public func convert(_ celsius: Double) -> Double { self == .celsius ? celsius : celsius * 9 / 5 + 32 }
}
