import SwiftUI
import AppKit
import FlightDeckCore

// Peripherals destination: USB tree, Thunderbolt/USB4, displays, Bluetooth (with battery levels), audio devices and the
// power adapter, from `Peripherals.collect()`. Loaded when the page appears and on Refresh only, never per sample.

struct PeripheralsView: View {
    @Environment(\.palette) var p
    @StateObject var loader = Loader { Peripherals.collect() }
    /// HDR capability per CGDirectDisplayID, read from NSScreen on the main thread when the report arrives.
    @State private var hdr: [UInt32: Bool] = [:]

    var body: some View {
        if Demo.isEnabled {
            DemoUnavailable(what: "Peripherals lists the devices connected to this Mac")
        } else {
            MaybeScroll {
                VStack(spacing: 12) {
                    HStack {
                        Text("Devices connected to or paired with this Mac. Fields a device doesn't report are shown as \"not reported\".")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                        Spacer()
                        if loader.loading { ProgressView().controlSize(.small) }
                        Button("Refresh") { loader.load() }.disabled(loader.loading)
                    }
                    if let r = loader.value { sections(r) } else { ProgressView("Reading devices…").padding(30) }
                }.padding(16)
            }
            .onAppear { loader.load(); hdr = Self.screenHDR() }
            .onChange(of: loader.value?.displays.count) { hdr = Self.screenHDR() }
        }
    }

    /// NSScreen's potential EDR headroom above 1.0 means the display can show HDR content.
    static func screenHDR() -> [UInt32: Bool] {
        var out: [UInt32: Bool] = [:]
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                out[n.uint32Value] = s.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
            }
        }
        return out
    }

    @ViewBuilder func sections(_ r: PeripheralsReport) -> some View {
        if let e = r.profilerError { Text("Only USB is shown: \(e).").foregroundStyle(.orange).font(.system(size: 11)) }
        Panel(title: "USB", trailing: r.usb.isEmpty ? "no devices" : "\(r.usb.count) devices") {
            ForEach(Peripherals.usbTree(r.usb), id: \.device.id) { item in
                let d = item.device
                Row(icon: "cable.connector", title: d.name, indent: item.depth, facts: [
                    d.vendor ?? d.vendorID.map { String(format: "vendor 0x%04x", $0) },
                    d.speed ?? "speed not reported",
                    d.powerAllocatedmA.map { "\($0) mA allocated" + (d.powerCapabilitymA.map { " (max \($0) mA)" } ?? "") } ?? "power not reported",
                ])
            }
        }
        Panel(title: "Thunderbolt / USB4", trailing: r.thunderbolt.isEmpty ? "none reported" : nil) {
            ForEach(r.thunderbolt) { b in
                VStack(alignment: .leading, spacing: 3) {
                    Row(icon: "bolt.horizontal", title: b.name, facts: b.ports)
                    ForEach(b.devices, id: \.self) { Row(icon: "externaldrive.connected.to.line.below", title: $0, indent: 1, facts: []) }
                }
            }
        }
        Panel(title: "Displays") {
            ForEach(r.displays) { d in
                let h = d.displayID.flatMap { hdr[$0] }
                Row(icon: "display", title: d.name + (d.isMain ? " (main)" : ""), facts: [
                    d.resolution.map { "looks like \($0)" }, d.pixels.map { "\($0) pixels" },
                    d.refreshHz.map { String(format: "%.0f Hz", $0) } ?? "refresh not reported",
                    h.map { $0 ? "HDR" : "SDR" } ?? "HDR not determined", d.connection, d.gpu,
                ])
            }
        }
        Panel(title: "Bluetooth", trailing: r.bluetoothState.map { "Bluetooth " + $0.lowercased() }) {
            if r.bluetooth.isEmpty { Text("No paired devices reported.").foregroundStyle(p.dim).font(.system(size: 11)) }
            ForEach(r.bluetooth) { d in
                // Order the battery parts the way AirPods-style devices are usually described.
                let parts = ["Main", "Left", "Right", "Case"].compactMap { k in d.battery[k].map { (k == "Main" ? "battery" : k.lowercased()) + " \($0)%" } }
                Row(icon: d.connected ? "dot.radiowaves.left.and.right" : "circle.dashed", title: d.name, dim: !d.connected, facts: [
                    d.connected ? "connected" : "not connected", d.kind,
                    d.connected ? (parts.isEmpty ? "battery not reported" : parts.joined(separator: " · ")) : nil,
                ])
            }
        }
        Panel(title: "Audio") {
            ForEach(r.audio) { a in
                let def = [a.defaultOutput ? "default output" : nil, a.defaultInput ? "default input" : nil].compactMap { $0 }
                Row(icon: a.outputs != nil ? "speaker.wave.2" : "mic", title: a.name, facts: [
                    def.isEmpty ? nil : def.joined(separator: ", "),
                    a.sampleRate.map { String(format: "%.1f kHz", $0 / 1000) },
                    a.inputs.map { "\($0) in" }, a.outputs.map { "\($0) out" }, a.transport, a.manufacturer,
                ])
            }
        }
        Panel(title: "Power adapter") {
            if let pw = r.power, pw.connected != false {
                Row(icon: "powerplug", title: pw.name ?? "Power adapter", facts: [
                    pw.watts.map { "\($0) W" } ?? "wattage not reported",
                    pw.charging.map { $0 ? "charging" : "not charging" }, pw.manufacturer,
                ])
            } else {
                Text(r.power == nil ? "No power adapter information reported." : "No power adapter connected.").foregroundStyle(p.dim).font(.system(size: 11))
            }
        }
    }
}

/// One device line: icon, name and dot-separated facts (nil facts are dropped).
private struct Row: View {
    @Environment(\.palette) var p
    var icon: String
    var title: String
    var indent = 0
    var dim = false
    var facts: [String?]
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(p.dim)
            Text(title).foregroundStyle(dim ? p.dim : p.text).lineLimit(1)
            Text(facts.compactMap { $0 }.joined(separator: " · ")).foregroundStyle(p.dim).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.leading, CGFloat(indent) * 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
