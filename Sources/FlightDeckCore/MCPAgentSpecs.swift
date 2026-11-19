import Foundation
// Schemas of the tools for coding agents measuring their own work: mark, marks, measure, query_metrics and
// process_logs. Kept apart from MCPTools.swift so that list stays readable; `MCPTools.specs` appends these.

extension MCPTools {
    /// How time arguments are written, shared by every tool here.
    static let timeHelp = "A mark id or label (the latest mark with that label), an ISO 8601 time, \"now\", or a relative time like \"-15m\", \"-2h\" or \"-90s\"."

    static var agentSpecs: [MCPToolSpec] {
        [
            MCPToolSpec(name: "mark", title: "Mark a moment",
                        description: "Records a named timestamp (e.g. 'tests-start') so the work after it can be measured with measure. Returns the mark's id and time, and whether the black box is recording. Writes only FlightDeck's own marks file (kept 48 h); marks also appear on the Flight Log timeline for the user. Works without the app, but measuring needs the app's black box.",
                        inputSchema: Self.schema([("label", ["type": "string", "description": "Short name for the moment, e.g. 'build-start', 'baseline-end'."])], required: ["label"]),
                        readOnly: false),
            MCPToolSpec(name: "marks", title: "List marks",
                        description: "Recent marks (newest first) with id, label, time and age.",
                        inputSchema: Self.schema([
                            ("hours", Self.int("How far back to list.", 1, 48, 24)),
                            ("limit", Self.int("Marks to return.", 1, 200, 30)),
                        ])),
            MCPToolSpec(name: "measure", title: "Measure a window",
                        description: "What the Mac did between two moments (marks, times, or a mark and now; within the black box's 24 h): CPU avg/p95/peak and CPU-seconds, memory used and pressure, swap growth, disk read/write totals, network totals, energy (Wh), hottest temperature and thermal throttling, and the top processes and apps by CPU-seconds, peak memory, energy and disk. With process or app: that process tree's cost including all recorded children (builds, test runners), from cumulative CPU time. With compare_to: the same figures for a baseline window, deltas, and a plain-English verdict (slower/faster, hungrier/leaner). Short-lived processes (under one sample interval) are undercounted.",
                        inputSchema: Self.schema([
                            ("from", ["type": "string", "description": .str("Start of the window. " + Self.timeHelp)]),
                            ("to", ["type": "string", "description": .str("End of the window (default now). " + Self.timeHelp)]),
                            ("process", ["type": "string", "description": "Only this process tree: a PID, or a process name (e.g. 'xcodebuild', 'swift-build', 'node'); children are included."]),
                            ("app", ["type": "string", "description": "Only this app's processes and their children (helpers roll into the app), e.g. 'Xcode', 'Terminal'."]),
                            ("compare_to", ["type": "object", "description": "A baseline window to compare with, e.g. the previous run's marks.",
                                            "properties": ["from": ["type": "string", "description": .str(Self.timeHelp)],
                                                           "to": ["type": "string", "description": .str(Self.timeHelp + " Default now.")]],
                                            "required": ["from"], "additionalProperties": false]),
                        ], required: ["from"])),
            MCPToolSpec(name: "query_metrics", title: "Metric time series",
                        description: "Raw time series from the black box on a regular grid, columnar: t (seconds from start) and one array per metric. Downsampled by average (max for hottest_c, swap and rss; the output says which). null = no data (asleep, not recorded, or the process not among the recorded busiest), never 0. Every sample for the last hour, one per 10 s for 24 h. If the answer would be too large, it asks for a larger step.",
                        inputSchema: Self.schema([
                            ("metrics", ["type": "array", "minItems": 1, "maxItems": 12,
                                         "description": .str("Any of: \(MetricSeries.systemNames.joined(separator: ", ")); or per process 'process:<pid or name>.cpu|rss|energy' (a name sums every process with that name)."),
                                         "items": ["type": "string"]]),
                            ("from", ["type": "string", "description": .str("Start (default -60m). " + Self.timeHelp)]),
                            ("to", ["type": "string", "description": .str("End (default now). " + Self.timeHelp)]),
                            ("step", ["type": "number", "description": "Seconds per point (default: the smallest of 1, 2, 5, 10, 15, 30, 60 … s giving at most 300 points; never below the sampling interval).", "minimum": 1, "maximum": 3600]),
                        ], required: ["metrics"])),
            MCPToolSpec(name: "process_logs", title: "Logs for a process",
                        description: "Unified-log messages from one app, PID or subsystem, grouped (messages differing only in numbers or ids collapse) with counts, newest first. Levels: error (errors and faults, default), fault, default, info (each includes the levels above it). Windows up to 24 h for errors, 60 min for default/info. macOS replaces non-public arguments with <private>. Bounded by a 20 s timeout and 20,000 messages.",
                        inputSchema: Self.schema([
                            ("app", ["type": "string", "description": "App or process name, e.g. 'Safari', 'Xcode', 'node' (helpers inside the app bundle included)."]),
                            ("pid", ["type": "integer", "description": "Process ID."]),
                            ("subsystem", ["type": "string", "description": "Subsystem, e.g. 'com.apple.network' (includes its sub-subsystems)."]),
                            ("from", ["type": "string", "description": .str("Start (instead of last_minutes). " + Self.timeHelp)]),
                            ("to", ["type": "string", "description": .str("End (default now). " + Self.timeHelp)]),
                            ("last_minutes", Self.int("Window ending at `to` (default 15).", 1, 1440, 15)),
                            ("level", Self.enumeration("Lowest level to include.", ProcessLogs.Level.allCases.map(\.rawValue), "error")),
                            ("limit", Self.int("Groups to return.", 1, 100, 30)),
                        ])),
        ]
    }
}
