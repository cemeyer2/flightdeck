import SwiftUI
import FlightDeckCore
// Network › "Network by app" panel: per-app (or per-process) traffic built from `ProcessSample.network`, which the
// core fills from `/usr/bin/nettop` (see ProcessNetworkSampler). Also hosts `AppGrouping`, the helper→app roll-up
// shared with other views, and the small two-colour `TrafficBar`.

/// One row of the traffic table: a whole app (all its helper processes summed) or a single process.
/// Rates are bytes/s for the latest sample; totals are bytes since FlightDeck started sampling that process.
struct AppTraffic: Identifiable {
    var id: String
    var name: String
    var iconPath: String
    /// Download / upload rate in bytes/s.
    var inBps = 0.0, outBps = 0.0
    /// Cumulative bytes received / sent since FlightDeck began watching (not since boot).
    var totalIn: UInt64 = 0, totalOut: UInt64 = 0
    /// How many processes were rolled into this row, and their summed open-connection count.
    var processes = 0, connections = 0
    /// Combined in+out bytes/s, used for sorting and bar scaling.
    var rate: Double { inBps + outBps }
}

/// Groups processes by the `.app` bundle they live in, so per-app numbers include all helpers.
enum AppGrouping {
    /// Outermost `.app` bundle in a path, so helpers (…/Chrome.app/…/Helper.app/…) roll up to the app.
    static func bundle(of path: String) -> String? { AppUsage.bundle(of: path) }

    // `nonisolated(unsafe)` because this is a plain static cache read and written only from SwiftUI body
    // evaluation on the main thread; it never needs invalidating since bundle names don't change while running.
    /// Localized app names hit the file system; cache them (the view re-renders every second).
    nonisolated(unsafe) static var names: [String: String] = [:]
    static func displayName(_ bundle: String) -> String {
        if let n = names[bundle] { return n }
        let n = (FileManager.default.displayName(atPath: bundle) as NSString).deletingPathExtension
        names[bundle] = n; return n
    }

    /// Sums per-process network samples into rows, grouped by app bundle (`byApp`) or kept per PID.
    /// Returns nil, not an empty list, when no process has network data at all: that means nettop is unavailable
    /// or still warming up (it needs two snapshots to produce deltas), which the panel reports differently from
    /// "no traffic". Processes outside any `.app` (daemons, CLI tools) stay as their own rows even in app mode.
    static func traffic(_ procs: [ProcessSample], byApp: Bool) -> [AppTraffic]? {
        guard procs.contains(where: { $0.network != nil }) else { return nil }
        var groups: [String: AppTraffic] = [:]
        for p in procs {
            guard let n = p.network else { continue }
            let key: String, name: String, icon: String
            if byApp, let b = bundle(of: p.path) {
                key = b; icon = b
                name = displayName(b)
            } else {
                key = "\(p.pid)"; name = p.name; icon = p.path
            }
            var g = groups[key] ?? AppTraffic(id: key, name: name, iconPath: icon)
            g.inBps += n.inBps; g.outBps += n.outBps; g.totalIn += n.totalIn; g.totalOut += n.totalOut
            g.processes += 1; g.connections += n.connections
            groups[key] = g
        }
        // Drop rows that have never moved a byte; sort by current rate, then by lifetime total so the order
        // stays meaningful (and stable) once everything goes idle.
        return groups.values.filter { $0.totalIn + $0.totalOut > 0 || $0.rate > 0 }
            .sorted { $0.rate != $1.rate ? $0.rate > $1.rate : ($0.totalIn + $0.totalOut) > ($1.totalIn + $1.totalOut) }
    }
}

/// Network › per-app traffic table. Reads only `e.current` (the latest live or replayed snapshot), so it works
/// unchanged during Flight Recorder replay. Shows the top `limit` rows unless "Show all" is on; both the
/// grouping and show-all choices persist in user defaults.
struct AppNetworkPanel: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @AppStorage("netByApp") private var byApp = true
    @AppStorage("netShowAll") private var showAll = false
    var limit = 12

    var body: some View {
        let rows = AppGrouping.traffic(e.current?.processes ?? [], byApp: byApp)
        Panel(title: byApp ? "Network by app" : "Network by process", trailing: "totals since FlightDeck started") {
            HStack {
                Picker("", selection: $byApp) { Text("Apps").tag(true); Text("Processes").tag(false) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                if let rows, rows.count > limit { Toggle("Show all (\(rows.count))", isOn: $showAll).toggleStyle(.switch) }
            }
            if let rows {
                let shown = showAll ? rows : Array(rows.prefix(limit))
                // Bars are scaled against the busiest visible row (floored at 1 B/s to avoid dividing by zero).
                let top = max(shown.first?.rate ?? 0, 1)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text(""); Text(byApp ? "App" : "Process")
                        Text("").gridColumnAlignment(.leading)
                        Text("↓ now"); Text("↑ now"); Text("↓ total"); Text("↑ total"); Text(byApp ? "Procs" : "Conns")
                    }.font(.meterLabel).foregroundStyle(p.dim)
                    ForEach(shown) { a in
                        GridRow {
                            // A bundle path needs a trailing "/" for AppIcon to resolve the app's icon rather than a
                            // generic folder; plain executable paths are passed through as-is.
                            AppIcon(path: a.iconPath.hasSuffix(".app") ? a.iconPath + "/" : a.iconPath).frame(width: 16, height: 16)
                            Text(a.name).lineLimit(1).frame(width: 190, alignment: .leading)
                            TrafficBar(inFrac: a.inBps / top, outFrac: a.outBps / top).frame(width: 140, height: 8)
                            Text(Fmt.rate(a.inBps)).foregroundStyle(a.inBps > 0 ? p.accent : p.dim)
                            Text(Fmt.rate(a.outBps)).foregroundStyle(a.outBps > 0 ? p.accent2 : p.dim)
                            Text(Fmt.bytes(a.totalIn)); Text(Fmt.bytes(a.totalOut))
                            Text("\(byApp ? a.processes : a.connections)").foregroundStyle(p.dim)
                        }.font(.system(size: 12, design: .monospaced))
                    }
                }
                if rows.isEmpty { Text("No network traffic observed yet.").foregroundStyle(p.dim) }
            } else {
                Text("Per-app traffic is warming up (needs two samples), or /usr/bin/nettop is unavailable.").foregroundStyle(p.dim)
            }
            Text("Measured from each process's open connections every sample. A connection that opens and closes between two samples isn't counted.")
                .font(.system(size: 10)).foregroundStyle(p.dim)
        }
    }
}

/// Horizontal bar showing download (accent) then upload (accent2) as fractions of the panel's busiest row,
/// with the remainder in the "off" meter colour. Fractions are clamped to 0...1.
struct TrafficBar: View {
    @Environment(\.palette) var p
    var inFrac: Double
    var outFrac: Double
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1) {
                Rectangle().fill(p.accent).frame(width: g.size.width * min(max(inFrac, 0), 1))
                Rectangle().fill(p.accent2).frame(width: g.size.width * min(max(outFrac, 0), 1))
                Rectangle().fill(p.meterOff)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
