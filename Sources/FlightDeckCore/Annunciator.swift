import Foundation
// The cockpit annunciator: one labelled light per subsystem, lit by the worst finding in it. Each light matches
// findings by id prefix (the ids are assigned by the Analyzer and DiagnosticReports, e.g. "cpu:<app>", "leak:<app>",
// "report:Crash…"). A finding can light more than one lamp (e.g. "cpu-throttled" lights CPU and THERM). Shared by
// the Summary panel and the web dashboard so both light the same lamps.

public enum Annunciator {
    public struct Light: Sendable {
        public var label: String
        /// Finding-id prefixes.
        public var match: [String]
        /// Default navigation target: a Destination raw value or "Performance:<tab>".
        public var dest: String
        public var key: String { label.lowercased() }
    }

    public static let lights: [Light] = [
        Light(label: "CPU", match: ["cpu:", "cpu-saturated", "unusual-cpu", "cpu-throttled", "wakeups:"], dest: "Performance:CPU"),
        Light(label: "MEM", match: ["mem-pressure", "leak:"], dest: "Performance:Memory"),
        Light(label: "SWAP", match: ["swap-", "swapping"], dest: "Performance:Memory"),
        Light(label: "THERM", match: ["thermal", "gpu-thermal", "cpu-throttled"], dest: "Performance:Thermals"),
        Light(label: "DISK", match: ["disk-busy", "drive:"], dest: "Performance:Disk"),
        Light(label: "STORAGE", match: ["disk-low", "disk-full"], dest: "Disk Space"),
        Light(label: "NET", match: ["net-", "wifi-weak"], dest: "Performance:Network"),
        Light(label: "GPU", match: ["gpu:", "gpu-recovery", "gpu-memory"], dest: "Performance:GPU"),
        Light(label: "POWER", match: ["unusual-power", "battery-health", "sleep-"], dest: "Performance:Energy"),
        Light(label: "HANG", match: ["hang:", "report:Hang"], dest: "Processes"),
        Light(label: "CRASH", match: ["report:Crash", "restart:"], dest: "Flight Log"),   // restart: unexpected shutdowns and panics (RestartFindings)
        Light(label: "AWAKE", match: ["awake:"], dest: "Processes"),
    ]

    /// The findings that light `light`, worst first. Callers pass findings that are already unmuted.
    public static func hits(_ light: Light, in findings: [Finding]) -> [Finding] {
        findings.filter { x in light.match.contains { x.id.hasPrefix($0) } }.sorted { $0.severity > $1.severity }
    }

    public static func level(_ light: Light, in findings: [Finding]) -> Finding.Severity? {
        hits(light, in: findings).first?.severity
    }
}
