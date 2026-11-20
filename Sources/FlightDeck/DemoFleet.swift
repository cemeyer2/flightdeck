// Demo mode's Fleet: three invented paired Macs (one with a memory warning, one offline) and one unpaired Mac nearby.
// Nothing here comes from this Mac or the network.
import Foundation
import FlightDeckCore

enum DemoFleet {
    static func model(now: Date = Date()) -> ([FleetHostState], [FleetAdvert]) {
        let studio = host(id: "demo-studio", name: "Design Studio", model: "Mac14,13", kind: "studio", macOS: "15.1", now: now,
                          cpu: 38, pressure: 86, level: 4, hottest: 58, memTotal: 64, memUsed: 61, diskFree: 212, diskTotal: 1000, battery: nil,
                          uptime: 9 * 86_400 + 3 * 3600, thermal: 0,
                          findings: [
                            FleetFinding(kind: "mem-pressure", severity: 3, icon: "memorychip", title: "Memory pressure is critical",
                                         detail: "Apps are being compressed and swapped; quit something large.", since: now.addingTimeInterval(-14 * 60)),
                            FleetFinding(kind: "swap-growing", severity: 2, icon: "arrow.left.arrow.right", title: "Swap grew by 6.2 GB in 10 minutes",
                                         detail: nil, since: now.addingTimeInterval(-9 * 60)),
                          ],
                          incidents: [
                            FleetFinding(kind: "mem-pressure", severity: 3, icon: "memorychip", title: "Memory pressure is critical", detail: nil,
                                         since: now.addingTimeInterval(-14 * 60)),
                            FleetFinding(kind: "hang", severity: 3, icon: "hourglass", title: "Final Cut Pro is not responding", detail: nil,
                                         since: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(-3 * 3600 + 95)),
                            FleetFinding(kind: "cpu-saturated", severity: 2, icon: "cpu", title: "CPU is 97% busy", detail: nil,
                                         since: now.addingTimeInterval(-26 * 3600), end: now.addingTimeInterval(-25 * 3600)),
                          ], seed: 1)
        let air = host(id: "demo-air", name: "Travel Air", model: "Mac15,12", kind: "laptop", macOS: "15.1", now: now,
                       cpu: 7, pressure: 22, level: 1, hottest: 36, memTotal: 16, memUsed: 9.5, diskFree: 141, diskTotal: 512,
                       battery: FleetBattery(percent: 81, charging: false, onPower: false), uptime: 2 * 86_400 + 5 * 3600, thermal: 0,
                       findings: [], incidents: [
                        FleetFinding(kind: "battery-health", severity: 1, icon: "battery.75", title: "Battery health is 91%", detail: nil,
                                     since: now.addingTimeInterval(-6 * 86_400), end: now.addingTimeInterval(-5 * 86_400)),
                       ], seed: 2)
        var mini = FleetHostState(peer: peer("demo-mini", "Basement Mini", model: "Mac14,3", kind: "mini", lastSeen: now.addingTimeInterval(-2 * 3600 - 840)))
        mini.online = false; mini.lastError = "No answer (the Mac may be asleep or off)"
        let nearby = [FleetAdvert(name: "Kitchen iMac", id: "demo-imac")]
        return ([studio, air, mini], nearby)
    }

    static func peer(_ id: String, _ name: String, model: String, kind: String, lastSeen: Date) -> FleetPeer {
        var p = FleetPeer(id: id, name: name, secret: Data(count: 32), pairedAt: lastSeen.addingTimeInterval(-40 * 86_400))
        p.model = model; p.kind = kind; p.lastSeen = lastSeen; p.serviceName = name
        return p
    }

    static func host(id: String, name: String, model: String, kind: String, macOS: String, now: Date, cpu: Double, pressure: Double, level: Int,
                     hottest: Double, memTotal: Double, memUsed: Double, diskFree: Double, diskTotal: Double, battery: FleetBattery?,
                     uptime: TimeInterval, thermal: Int, findings: [FleetFinding], incidents: [FleetFinding], seed: Int) -> FleetHostState {
        let gb = 1_000_000_000.0
        let vitals = FleetVitals(cpu: FleetValue(cpu), memoryPressure: FleetValue(pressure), memoryLevel: level,
                                 memoryUsed: FleetValue(memUsed * 1_073_741_824), memoryTotal: FleetValue(memTotal * 1_073_741_824), hottest: FleetValue(hottest),
                                 diskFree: FleetValue(diskFree * gb), diskTotal: FleetValue(diskTotal * gb), battery: battery,
                                 batteryReason: battery == nil ? "No battery" : nil, uptime: FleetValue(uptime), thermalState: thermal, sampledAt: now)
        let identity = FleetIdentity(id: id, name: name, model: model, kind: kind, macOS: macOS, appVersion: "1.3")
        let status = FleetStatus(identity: identity, vitals: vitals, findings: findings, incidents: incidents,
                                 history: history(now: now, cpu: cpu, pressure: pressure, hottest: hottest, seed: seed))
        var h = FleetHostState(peer: peer(id, name, model: model, kind: kind, lastSeen: now), status: status)
        h.online = true
        return h
    }

    /// 60 points over 30 minutes wandering towards the current values (a fixed pseudo-random walk per seed).
    static func history(now: Date, cpu: Double, pressure: Double, hottest: Double, seed: Int) -> [FleetPoint] {
        (0..<60).map { i in
            let x = Double(i) / 59, w = sin(Double(i * (seed + 2)) * 0.7) * 0.5 + sin(Double(i) * 0.23 + Double(seed)) * 0.5
            // The pressure climbs over the half hour on the Studio (seed 1), so its sparkline shows the trouble building.
            let p = seed == 1 ? 45 + (pressure - 45) * x + w * 3 : pressure + w * 4
            return FleetPoint(t: now.addingTimeInterval(Double(i - 59) * 30), cpu: max(1, cpu + w * cpu * 0.5),
                              memoryPressure: min(100, max(0, p)), hottest: hottest + w * 3)
        }
    }
}
