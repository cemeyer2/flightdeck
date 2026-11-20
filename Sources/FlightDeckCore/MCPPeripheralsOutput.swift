import Foundation
// Output of the read-only `peripherals` MCP tool: USB and Thunderbolt devices with negotiated vs supported link speeds
// and a plain-English diagnosis, plus accessory batteries with an estimate of the charge left. It runs the same
// IORegistry reads and one `system_profiler` call (about a second) as the Peripherals page, and reads the saved
// battery history without writing to it. Inferred capabilities are flagged.

extension MCPTools {
    func peripherals() async throws -> JSON {
        let now = self.now()
        let r = await Task.detached(priority: .utility) {
            Peripherals.collect(recorder: AccessoryRecorder(store: AccessoryStore(dir: AccessoryStore.defaultDirectory, readOnly: true)))
        }.value
        return Self.peripheralsJSON(links: r.links, accessories: r.accessories, now: now)
    }

    static func usbLinkJSON(_ l: USBLink) -> JSON {
        .object(dropping: [
            ("name", .str(l.name)), ("vendor", l.vendor.map(JSON.str)),
            ("kind", .str(l.isHub ? "hub" : l.isStorage ? "storage" : "device")),
            ("negotiated", l.negotiatedMbps.map { .str(LinkRate.usbName($0)) } ?? F.unavailable("not reported")),
            ("device_supports", .str(l.device.text)), ("device_support_inferred", l.device.inferred ? .bool(true) : nil),
            ("path_supports", .str(l.port.text)),
            ("hubs", l.hubs.isEmpty ? nil : .strings(l.hubs)),
            ("drive_max_mb_per_s", l.effectiveMBps.map { .int(Int($0)) }),
            ("status", .str(l.diagnosis.level.rawValue)), ("diagnosis", .str(l.diagnosis.summary)), ("advice", l.diagnosis.advice.map(JSON.str)),
        ])
    }

    static func thunderboltLinkJSON(_ t: ThunderboltLink) -> JSON {
        .object(dropping: [
            ("name", .str(t.name)), ("vendor", t.vendor.map(JSON.str)), ("chain_depth", .int(t.depth)),
            ("upstream", t.upstreamName.map(JSON.str)),
            ("linked", t.currentGbps.map { .str(LinkRate.text($0 * 1000) + (t.currentMode.map { " (\($0))" } ?? "")) } ?? F.unavailable("not reported")),
            ("both_ends_support", t.maxGbps.map { .str(LinkRate.text($0 * 1000) + (t.maxMode.map { " (\($0))" } ?? "")) } ?? F.unavailable("not reported")),
            ("status", .str(t.diagnosis.level.rawValue)), ("diagnosis", .str(t.diagnosis.summary)), ("advice", t.diagnosis.advice.map(JSON.str)),
        ])
    }

    static func accessoryJSON(_ a: AccessoryBattery, now: Date) -> JSON {
        let levels: [(String, JSON?)] = a.orderedLevels.map { ($0.part.lowercased() + "_pct", .int($0.pct)) }
        let est: JSON
        switch a.estimate {
        case .value(let e): est = .object([("text", .str(e.text)), ("days_left", F.r1(e.daysLeft)), ("pct_per_day", F.r1(e.ratePerDay)), ("readings", .int(e.readings))])
        case .unavailable(let why): est = F.unavailable(why)
        }
        return .object(dropping: [("name", .str(a.name)), ("kind", a.kind.map(JSON.str)), ("connected", .bool(a.connected))] + levels + [
            ("last_reading", a.lastSeen.map(F.time)), ("readings_kept", .int(a.history.count)), ("estimate", est),
        ])
    }

    static func peripheralsJSON(links: LinkReport, accessories: [AccessoryBattery], now: Date) -> JSON {
        let slow = links.usb.filter { $0.diagnosis.level == .slow }.map(\.diagnosis.summary)
            + links.thunderbolt.filter { $0.diagnosis.level == .slow }.map(\.diagnosis.summary)
        let lowBatt = accessories.filter { a in a.connected && (a.levels["Main"] ?? 100) < AccessoryForecast.lowThreshold }.map { "\($0.name) is at \($0.levels["Main"]!)%." }
        let devices = "\(links.usb.count) USB and \(links.thunderbolt.count) Thunderbolt/USB4 devices"
        let summary = ([devices + (slow.isEmpty ? ", none linked below what they support." : ": \(slow.count) linked slower than they could.")] + slow + lowBatt)
            .joined(separator: " ")
        return .object([
            ("summary", .str(summary)),
            ("usb", .array(links.usb.map(usbLinkJSON))),
            ("thunderbolt", .array(links.thunderbolt.map(thunderboltLinkJSON))),
            ("accessory_batteries", .array(accessories.map { accessoryJSON($0, now: now) })),
            ("notes", .strings([
                "A USB 3 device that fell back to USB 2 reports itself like a USB 2 device, so that case is only diagnosed when its descriptor says USB 3 or it is an SSD (flagged as inferred).",
                "Battery levels of AirPods and other headsets are read only when the Peripherals page or this tool loads; Apple's Magic accessories are recorded every 20 minutes while FlightDeck runs.",
            ])),
        ])
    }
}
