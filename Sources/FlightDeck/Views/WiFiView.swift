// Wi-Fi destination: a Wi-Fi analyzer. Your link now (health ratings and why the rate might be low), its history while
// the page is open (with roams and band changes marked), a walk-test readout, nearby networks from a scan, channel
// congestion per band with a recommendation, and a UniFi console's own radio utilization when one is set up.
// Panels are in WiFiLinkPanels.swift, WiFiNetworksPanel.swift and WiFiCongestionPanel.swift; state is WiFiModel.
import SwiftUI
import FlightDeckCore

struct WiFiView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @ObservedObject var model: WiFiModel = .shared
    @ObservedObject var unifi: UniFiModel = .shared

    var body: some View {
        // Derived once per render: the own-network ids, the recommendation and the health report all depend on both
        // the scan and the link.
        let link = model.link
        let scan = model.scan
        let own = scan.map { WiFiCongestion.ownIDs($0, linkRSSI: link?.point.rssi) } ?? []
        let rec: WiFiRecommendation? = {
            guard let scan, let l = link?.point, let b = l.band, let c = l.channel else { return nil }
            return WiFiCongestion.recommend(scan, band: b, channel: c, widthMHz: l.widthMHz, linkRSSI: l.rssi)
        }()
        let radios = WiFiUniFiRadios.list(unifi.isConfigured ? unifi.snapshot : nil)
        let util = WiFiUniFiRadios.utilization(radios, band: link?.point.band, channel: link?.point.channel)
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                WiFiControlPanel(model: model)
                if model.walkTest {
                    WalkTestPanel(point: link?.point)
                }
                HStack(alignment: .top, spacing: 12) {
                    WiFiHealthPanel(link: link, recommendation: rec, utilization: util)
                    WiFiLinkHistoryPanel(history: model.history)
                }
                if let scan {
                    WiFiCongestionPanel(scan: scan, own: own, recommendation: rec, ownBand: link?.point.band)
                    WiFiNetworksPanel(scan: scan, own: own)
                }
                if !radios.isEmpty { WiFiUniFiPanel(radios: radios, demo: unifi.snapshot?.source == .demo) }
            }
            .padding(16)
        }
        .onAppear { model.appear(e) }
        .onDisappear { model.disappear() }
    }
}

/// Scan controls, the auto-scan toggle, walk test, and the Location permission explanation when names are hidden.
struct WiFiControlPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: WiFiModel

    var body: some View {
        Panel(title: "Nearby networks", trailing: model.demo ? "demo data: no scan runs" : model.scan.map { "last scan " + $0.time.formatted(date: .omitted, time: .standard) }) {
            HStack(spacing: 14) {
                Button { model.scanNow() } label: { Label("Scan", systemImage: "antenna.radiowaves.left.and.right") }
                    .disabled(model.demo || model.scanning)
                if model.scanning { ProgressView().controlSize(.small); Text("Scanning…").font(.caption).foregroundStyle(p.text) }
                Toggle("Rescan every \(Int(WiFiModel.autoInterval)) s while this page is open", isOn: $model.autoScan)
                    .toggleStyle(.checkbox).disabled(model.demo)
                Toggle("Walk test", isOn: $model.walkTest).toggleStyle(.checkbox)
                    .help("A big live signal readout for walking around to find dead spots")
                Spacer(minLength: 0)
            }
            Text("A scan makes the Wi-Fi radio listen on every channel for a moment, which can stall your connection for a second or two, so FlightDeck only scans when you ask. Scans are kept in memory only.")
                .font(.caption).foregroundStyle(p.dim).lineLimit(3)
            if let err = model.scanError {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(p.warn)
            }
            if model.permission != .granted && !model.demo {
                LocationPermissionNote(model: model)
            }
        }
    }
}

/// Why names are hidden, and the button that asks for permission (the only place FlightDeck asks).
struct LocationPermissionNote: View {
    @Environment(\.palette) var p
    @ObservedObject var model: WiFiModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "location.slash").foregroundStyle(p.warn)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.scan?.identifiersHidden == true ? "Network names and BSSIDs are hidden" : "Network names and BSSIDs need Location permission")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(p.text)
                Text(WiFiPermission.explanation(model.permission) + " Without it, channels, signal and congestion still work, but roaming between access points can't be told apart from a channel change.")
                    .font(.caption).foregroundStyle(p.dim).lineLimit(5)
                if model.permission == .notDetermined {
                    if model.canRequestLocation {
                        Button("Allow Location Access…") { model.requestLocation() }
                    } else {
                        Text("This copy of FlightDeck isn't a bundled app, so macOS can't ask; build it with scripts/bundle.sh.")
                            .font(.caption).foregroundStyle(p.dim)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.warn.opacity(0.08)))
    }
}

/// Rating colour and icon, so status is never colour alone.
extension WiFiRating {
    func color(_ p: Palette) -> Color {
        switch self { case .excellent, .good: p.accent; case .fair: p.warn; case .poor: p.crit; case .unknown: p.dim }
    }
    var icon: String {
        switch self { case .excellent, .good: "checkmark.circle"; case .fair: "exclamationmark.triangle"; case .poor: "xmark.octagon"; case .unknown: "questionmark.circle" }
    }
}
