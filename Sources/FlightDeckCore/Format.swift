import Foundation

public enum Fmt {
    public static func bytes(_ b: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = b, i = 0
        while abs(v) >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? String(format: "%.0f %@", v, units[i]) : String(format: "%.1f %@", v, units[i])
    }
    public static func bytes(_ b: UInt64) -> String { bytes(Double(b)) }
    public static func rate(_ bps: Double) -> String { bytes(bps) + "/s" }
    public static func bits(_ bps: Double) -> String {
        let units = ["bps", "Kbps", "Mbps", "Gbps"]
        var v = bps * 8, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return String(format: "%.1f %@", v, units[i])
    }
    public static func pct(_ p: Double) -> String { String(format: "%.1f%%", p) }
    public static func duration(_ s: TimeInterval) -> String {
        let t = Int(s); let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60, sec = t % 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        return String(format: "%d:%02d:%02d", h, m, sec)
    }
}
