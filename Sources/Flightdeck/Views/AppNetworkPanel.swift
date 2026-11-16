import SwiftUI
import FlightdeckCore

struct AppTraffic: Identifiable {
    var id: String
    var name: String
    var iconPath: String
    var inBps = 0.0, outBps = 0.0
    var totalIn: UInt64 = 0, totalOut: UInt64 = 0
    var processes = 0, connections = 0
    var rate: Double { inBps + outBps }
}

enum AppGrouping {
    /// Outermost `.app` bundle in a path, so helpers (…/Chrome.app/…/Helper.app/…) roll up to the app.
    static func bundle(of path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func traffic(_ procs: [ProcessSample], byApp: Bool) -> [AppTraffic]? {
        guard procs.contains(where: { $0.network != nil }) else { return nil }
        var groups: [String: AppTraffic] = [:]
        for p in procs {
            guard let n = p.network else { continue }
            let key: String, name: String, icon: String
            if byApp, let b = bundle(of: p.path) {
                key = b; icon = b
                name = (FileManager.default.displayName(atPath: b) as NSString).deletingPathExtension
            } else {
                key = "\(p.pid)"; name = p.name; icon = p.path
            }
            var g = groups[key] ?? AppTraffic(id: key, name: name, iconPath: icon)
            g.inBps += n.inBps; g.outBps += n.outBps; g.totalIn += n.totalIn; g.totalOut += n.totalOut
            g.processes += 1; g.connections += n.connections
            groups[key] = g
        }
        return groups.values.filter { $0.totalIn + $0.totalOut > 0 || $0.rate > 0 }
            .sorted { $0.rate != $1.rate ? $0.rate > $1.rate : ($0.totalIn + $0.totalOut) > ($1.totalIn + $1.totalOut) }
    }
}

struct AppNetworkPanel: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @AppStorage("netByApp") private var byApp = true
    @AppStorage("netShowAll") private var showAll = false
    var limit = 12

    var body: some View {
        let rows = AppGrouping.traffic(e.current?.processes ?? [], byApp: byApp)
        Panel(title: byApp ? "Network by app" : "Network by process", trailing: "totals since Flightdeck started") {
            HStack {
                Picker("", selection: $byApp) { Text("Apps").tag(true); Text("Processes").tag(false) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                if let rows, rows.count > limit { Toggle("Show all (\(rows.count))", isOn: $showAll).toggleStyle(.switch) }
            }
            if let rows {
                let shown = showAll ? rows : Array(rows.prefix(limit))
                let top = max(shown.first?.rate ?? 0, 1)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text(""); Text(byApp ? "App" : "Process")
                        Text("").gridColumnAlignment(.leading)
                        Text("↓ now"); Text("↑ now"); Text("↓ total"); Text("↑ total"); Text(byApp ? "Procs" : "Conns")
                    }.font(.meterLabel).foregroundStyle(p.dim)
                    ForEach(shown) { a in
                        GridRow {
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
