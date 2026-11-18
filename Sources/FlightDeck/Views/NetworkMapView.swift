import SwiftUI
import FlightDeckCore

// Network destination: a flight deck for the local network. The map (NetworkMapCanvas.swift) on the left; the
// selected device, this network's facts and the discovery controls on the right; a sortable list of every device
// below. Data comes from NetworkMapModel, which only works while this view is visible.

struct NetworkMapView: View {
    @Environment(\.palette) var p
    @ObservedObject var model: NetworkMapModel = .shared
    @State private var hovered: String?

    var body: some View {
        GeometryReader { geo in
            // Map height: most of the window, but leave the list's header in view; never below 440.
            let mapW = max(520, geo.size.width - 32 - 12 - 340 - 24)
            let mapH = max(440, min(geo.size.height - 32 - 140, mapW * 0.8))
            MaybeScroll {
                VStack(alignment: .leading, spacing: 12) {
                    if let s = model.survey {
                        HStack(alignment: .top, spacing: 12) {
                            Panel(title: "Network map", trailing: "\(s.devices.count) device\(s.devices.count == 1 ? "" : "s") · updated \(s.time.formatted(date: .omitted, time: .shortened))") {
                                NetworkMap(survey: s, hops: model.hops, selected: $model.selected, hovered: $hovered)
                                    .frame(height: mapH + CGFloat(max(0, s.topology.branches.count - 1)) * NetMapLayout.laneH)
                            }
                            VStack(spacing: 12) {
                                DeviceDetailPanel(d: s.device(hovered ?? model.selected) ?? s.devices.first { $0.isGateway },
                                                  pinned: hovered == nil && model.selected != nil)
                                NetworkFactsPanel(s: s)
                                DiscoveryPanel(model: model)
                            }
                            .frame(width: 340)
                        }
                        DeviceListPanel(devices: s.devices, selected: $model.selected)
                    } else {
                        HStack { ProgressView().controlSize(.small); Text("Looking at the local network…").foregroundStyle(p.text) }.padding(30)
                    }
                }
                .padding(16)
            }
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }
}

/// Friendly names for the service types BonjourBrowser looks for.
func serviceLabel(_ t: String) -> String {
    let base = t.split(separator: ".").first.map(String.init) ?? t
    let names = [
        "_airplay": "AirPlay", "_raop": "AirPlay audio", "_googlecast": "Google Cast", "_spotify-connect": "Spotify Connect",
        "_sonos": "Sonos", "_amzn-wplay": "Fire TV", "_ipp": "IPP printing", "_ipps": "IPP printing (TLS)", "_printer": "LPD printing",
        "_pdl-datastream": "raw printing", "_uscan": "AirScan", "_scanner": "scanner", "_smb": "SMB file sharing",
        "_afpovertcp": "AFP file sharing", "_ssh": "SSH", "_sftp-ssh": "SFTP", "_rfb": "screen sharing", "_hap": "HomeKit",
        "_homekit": "HomeKit", "_matter": "Matter", "_hue": "Hue", "_companion-link": "Apple Continuity",
        "_device-info": "device info", "_http": "web page", "_https": "web page (TLS)",
    ]
    return names[base] ?? base
}

/// Everything known about one device, with unknowns spelled out.
struct DeviceDetailPanel: View {
    @Environment(\.palette) var p
    var d: NetDevice?
    var pinned: Bool

    func row(_ k: String, _ v: String, dim: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(k).foregroundStyle(p.dim).frame(width: 82, alignment: .leading)
            Text(v).foregroundStyle(dim ? p.dim : p.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    var body: some View {
        Panel(title: d == nil ? "Device" : (pinned ? "Selected device" : (d?.isGateway == true ? "Gateway" : "Device")), trailing: d?.kind.rawValue) {
            if let d {
                HStack(spacing: 10) {
                    Image(systemName: d.kind.icon).font(.system(size: 22)).foregroundStyle(p.accent).frame(width: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                        Text("Why \(d.kind.rawValue.lowercased()): \(d.kindReason)")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                row("IPv4", d.ipv4.isEmpty ? "none seen" : d.ipv4.joined(separator: ", "), dim: d.ipv4.isEmpty)
                row("IPv6", d.ipv6.isEmpty ? "none seen" : d.ipv6.joined(separator: "\n"), dim: d.ipv6.isEmpty)
                row("MAC", d.mac.map { $0 + (MAC.isLocallyAdministered($0) ? " (private)" : "") } ?? "unknown: not in this Mac's ARP/NDP cache", dim: d.mac == nil)
                row("Vendor", d.vendor.label, dim: d.vendor.name == nil)
                if let m = d.manufacturer { row("Manufacturer", m + " (UPnP)") }
                row("Model", d.model ?? "not advertised", dim: d.model == nil)
                // Physical attachment comes only from a UniFi console; without one it can't be known from this Mac.
                row("Connected", d.attachment ?? (d.isThisMac ? "this Mac" : "unknown: needs a network controller (Settings › UniFi)"),
                    dim: d.attachment == nil)
                if let n = d.unifiName { row("UniFi name", n) }
                if let n = d.upnpName { row("UPnP name", n) }
                row("Hostname", d.hostname ?? "no reverse-DNS name", dim: d.hostname == nil)
                row("Bonjour", d.bonjourHost.map { $0 + ".local" } ?? "advertises nothing", dim: d.bonjourHost == nil)
                if !d.services.isEmpty { row("Services", d.services.map(serviceLabel).joined(separator: ", ")) }
                row("Interface", d.interface ?? "unknown", dim: d.interface == nil)
                if !d.isThisMac {
                    row("First seen", d.firstSeen.formatted(date: .omitted, time: .shortened) + " (this session)")
                    row("Last seen", d.lastSeen.formatted(date: .omitted, time: .standard))
                }
                row("Seen via", d.sources.joined(separator: ", "))
            } else {
                Text("Hover or click a device.").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
            }
        }
    }
}
