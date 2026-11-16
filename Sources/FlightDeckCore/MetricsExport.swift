import Foundation
import Network
// Metrics export for other tools: `PrometheusText` renders one Snapshot as Prometheus text exposition format
// (version 0.0.4, which OpenMetrics scrapers also accept), and `MetricsServer` serves it over HTTP on localhost with
// Network.framework. The server does nothing between scrapes: no timer, no polling; each request asks its `render`
// closure for the current text. Unmeasured values are omitted, never written as 0.

/// Prometheus text format for a Snapshot.
public enum PrometheusText {
    /// HTTP Content-Type for the format produced here.
    public static let contentType = "text/plain; version=0.0.4; charset=utf-8"
    /// Process series are limited to this many (by CPU), and names truncated, so label cardinality stays bounded.
    public static let topProcesses = 20
    static let maxLabelLength = 64

    /// One metric family: a name, help text, and its samples (labels, value).
    struct Family {
        var name: String, help: String, type = "gauge"
        var samples: [(labels: [(String, String)], value: Double)] = []
        mutating func add(_ v: Double?, _ labels: [(String, String)] = []) {
            // Only real numbers: nil means unmeasured, and NaN/inf would just confuse a scraper.
            if let v, v.isFinite { samples.append((labels, v)) }
        }
    }

    /// Escapes a label value: backslash, double quote and newline, as the format requires.
    static func escapeLabel(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    }
    /// HELP text escapes only backslash and newline.
    static func escapeHelp(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    }
    /// Shortest exact form ("12.5", "3", "1e+21"); integral values print without a fraction.
    static func number(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    /// Text for families; a family with no samples is left out entirely (no HELP/TYPE for nothing).
    static func render(_ families: [Family]) -> String {
        var out = ""
        for f in families where !f.samples.isEmpty {
            out += "# HELP \(f.name) \(escapeHelp(f.help))\n# TYPE \(f.name) \(f.type)\n"
            for s in f.samples {
                let l = s.labels.isEmpty ? "" : "{" + s.labels.map { "\($0.0)=\"\(escapeLabel($0.1))\"" }.joined(separator: ",") + "}"
                out += "\(f.name)\(l) \(number(s.value))\n"
            }
        }
        return out
    }

    /// The full exposition for one snapshot.
    public static func render(_ s: Snapshot) -> String {
        func fam(_ name: String, _ help: String) -> Family { Family(name: "flightdeck_" + name, help: help) }
        var cpu = fam("cpu_usage_percent", "CPU usage as % of all cores, by mode (total, user, system).")
        cpu.add(s.cpu.total.value, [("mode", "total")]); cpu.add(s.cpu.user.value, [("mode", "user")]); cpu.add(s.cpu.system.value, [("mode", "system")])
        var core = fam("cpu_core_usage_percent", "Per-core CPU usage %, with the core kind (performance, efficiency).")
        // Per-core values come from the same tick counters as the total, so they exist exactly when the total does.
        if s.cpu.total.isAvailable {
            for c in s.cpu.cores { core.add(c.total, [("core", "\(c.index)"), ("kind", c.kind.rawValue)]) }
        }
        var load = fam("load_average", "Load average over 1, 5 and 15 minutes.")
        for (w, v) in zip(["1m", "5m", "15m"], s.cpu.loadAverage) { load.add(v, [("window", w)]) }
        // Memory byte counts are placeholders when the VM statistics couldn't be read (`isMeasured` false).
        var memUsed = fam("memory_used_bytes", "Memory used (app + wired + compressed), bytes.")
        var memTotal = fam("memory_total_bytes", "Installed memory, bytes.")
        if s.memory.isMeasured { memUsed.add(Double(s.memory.used)); memTotal.add(Double(s.memory.total)) }
        var pressure = fam("memory_pressure_percent", "Memory pressure, 0-100.")
        pressure.add(s.memory.pressure.value)
        var swap = fam("swap_used_bytes", "Swap in use, bytes.")
        swap.add(s.memory.swapUsed.value)
        var disk = fam("disk_bytes_per_second", "Storage throughput, bytes per second, by direction.")
        disk.add(s.disk.readBps.value, [("direction", "read")]); disk.add(s.disk.writeBps.value, [("direction", "write")])
        var net = fam("network_bytes_per_second", "Network throughput, bytes per second, by direction.")
        net.add(s.network.inBps.value, [("direction", "receive")]); net.add(s.network.outBps.value, [("direction", "transmit")])
        var watts = fam("system_power_watts", "Whole-system power draw, watts.")
        watts.add(s.power.systemWatts.value)
        var hot = fam("temperature_hottest_celsius", "Hottest temperature sensor, degrees Celsius.")
        hot.add(s.power.hottest.value)
        var thermal = fam("thermal_state", "macOS thermal state: 0 nominal, 1 fair, 2 serious, 3 critical.")
        thermal.add(Double(s.power.thermalState))
        var fan = fam("fan_rpm", "Fan speed, revolutions per minute.")
        for f in s.power.fans ?? [] { fan.add(f.rpm, [("fan", "\(f.index)")]) }
        var gpu = fam("gpu_usage_percent", "GPU utilisation %.")
        gpu.add(s.gpu.value)
        var battery = fam("battery_percent", "Battery charge %.")
        battery.add(s.power.battery?.percent)

        var pcpu = fam("process_cpu_percent", "Process CPU usage as % of one core (top \(topProcesses) processes by CPU).")
        var pmem = fam("process_memory_bytes", "Process physical memory footprint, bytes (top \(topProcesses) processes by CPU).")
        var pwatt = fam("process_energy_watts", "Process energy use, watts (top \(topProcesses) processes by CPU).")
        for p in s.processes.sorted(by: { $0.cpu > $1.cpu }).prefix(topProcesses) {
            let labels = [("name", String(p.name.prefix(maxLabelLength))), ("pid", "\(p.pid)")]
            // A restricted process (another user's, unreadable) reports placeholder zeros when the kernel refused the
            // counters; those are omitted rather than exported as an idle process.
            pcpu.add(p.restricted && p.cpuTime == 0 ? nil : p.cpu, labels)
            pmem.add(p.restricted && p.memory == 0 ? nil : Double(p.memory), labels)
            pwatt.add(p.energyWatts, labels)
        }
        var ts = fam("snapshot_timestamp_seconds", "When this snapshot was sampled, Unix time.")
        ts.add(s.time.timeIntervalSince1970.rounded())
        return render([cpu, core, load, memUsed, memTotal, pressure, swap, disk, net, watts, hot, thermal, fan, gpu, battery,
                       pcpu, pmem, pwatt, ts])
    }
}

/// A minimal HTTP/1.1 server for `GET /metrics`, bound to 127.0.0.1 only. Each connection gets one response and is
/// closed. Idle connections are dropped after 5 s, and at most 8 are served at once, so a misbehaving client can't
/// hold resources. All state lives on the server's private serial queue.
public final class MetricsServer: @unchecked Sendable {
    /// Produces the body for a scrape, or nil if there is nothing to export yet (answered with 503). Called on the
    /// server's queue; the app hops to the main actor inside it.
    public typealias Render = @Sendable (@escaping @Sendable (String?) -> Void) -> Void

    private let queue = DispatchQueue(label: "flightdeck.metrics", qos: .utility)
    private var listener: NWListener?
    private var connections = 0
    private let render: Render
    public let requestedPort: UInt16

    /// `port` 0 picks a free port (tests); read `port` once `start` has reported ready.
    public init(port: UInt16, render: @escaping Render) { requestedPort = port; self.render = render }

    /// The bound port while running.
    public private(set) var port: UInt16?

    /// Starts listening; `ready` is called once with nil on success or an error message.
    public func start(ready: @escaping @Sendable (String?) -> Void = { _ in }) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Binding to the loopback address means only processes on this Mac can connect.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let l: NWListener
        do { l = try NWListener(using: params) } catch { ready("\(error)"); return }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.port = l.port?.rawValue; ready(nil)
            case .failed(let e): ready("\(e)"); l.cancel()
            default: break
            }
        }
        l.start(queue: queue)
    }

    public func stop() {
        queue.async { [self] in listener?.cancel(); listener = nil; port = nil }
    }

    private func accept(_ c: NWConnection) {
        guard connections < 8 else { c.cancel(); return }
        connections += 1
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .cancelled, .failed: self?.queue.async { self?.connections -= 1 }
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { if c.state != .cancelled { c.cancel() } }
        receive(c, Data())
    }

    /// Reads until the end of the request headers (or 8 KB), then answers. The body of a request is never needed.
    private func receive(_ c: NWConnection, _ soFar: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = soFar; if let data { buf.append(data) }
            if buf.range(of: Data("\r\n\r\n".utf8)) != nil || buf.count >= 8192 || done || err != nil {
                self.respond(c, request: buf)
            } else {
                self.receive(c, buf)
            }
        }
    }

    private func respond(_ c: NWConnection, request: Data) {
        let line = String(decoding: request.prefix(while: { $0 != 0x0D && $0 != 0x0A }), as: UTF8.self).split(separator: " ")
        let path = line.count >= 2 ? line[1].split(separator: "?").first.map(String.init) ?? "" : ""
        guard line.first == "GET" || line.first == "HEAD" else { return send(c, status: "405 Method Not Allowed", body: "method not allowed\n") }
        guard path == "/metrics" else { return send(c, status: "404 Not Found", body: "FlightDeck serves /metrics\n") }
        let head = line.first == "HEAD"
        render { [weak self] text in
            self?.queue.async {
                guard let text else { self?.send(c, status: "503 Service Unavailable", body: "no sample yet\n"); return }
                self?.send(c, status: "200 OK", body: text, type: PrometheusText.contentType, headOnly: head)
            }
        }
    }

    private func send(_ c: NWConnection, status: String, body: String, type: String = "text/plain; charset=utf-8", headOnly: Bool = false) {
        let b = Data(body.utf8)
        var d = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(b.count)\r\nConnection: close\r\n\r\n".utf8)
        if !headOnly { d.append(b) }
        c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
    }
}
