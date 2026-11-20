import SwiftUI
import FlightDeckCore
// Displays destination: every connected display with its identity, current mode and refresh (ProMotion / variable
// range), HDR headroom, brightness, the video link and plain-English diagnoses, the full mode list, and this session's
// connects and mode changes. Data from DisplaysModel (DisplayCollector in FlightDeckCore); panels are in
// DisplayPanels.swift and DisplayHistoryPanel.swift.

struct DisplaysView: View {
    @Environment(\.palette) var p
    @StateObject private var model: DisplaysModel
    /// Renders open every mode list so they can be reviewed.
    var expandModes = false

    init(model: DisplaysModel? = nil, expandModes: Bool = false) {
        // Demo mode gets invented displays; nothing is read from this Mac.
        _model = StateObject(wrappedValue: model ?? (Demo.isEnabled ? DisplaysModel(preview: DemoDisplays.report()) : DisplaysModel()))
        self.expandModes = expandModes
    }

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Each display's mode, refresh, HDR and video link, and why it might not be running at its best.").foregroundStyle(p.dim)
                    if model.loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Refresh") { Task { await model.load() } }.disabled(model.loading || model.fixed)
                }.font(.system(size: 12))
                if let r = model.report { DisplaysContent(report: r, expandModes: expandModes) }
                else { Text(model.loading ? "Reading displays…" : "Not loaded yet.").foregroundStyle(p.dim) }
            }.padding(16)
        }
        .task { if model.report == nil { await model.load() } }
        // Connects, disconnects and mode changes while the page is open (no polling).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            Task { await model.load() }
        }
    }
}

/// The page's panels for a loaded report (also what UIBench renders).
struct DisplaysContent: View {
    @Environment(\.palette) var p
    var report: DisplaysReport
    var expandModes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            overview
            ForEach(report.displays) { d in DisplayCard(display: d, expandModes: expandModes) }
            if !report.unassignedLinks.isEmpty { UnassignedLinksPanel(links: report.unassignedLinks) }
            DisplayHistoryPanel(events: report.history, now: report.time)
            DisplayLimitsPanel(limits: report.limits)
        }
    }

    var overview: some View {
        Panel(title: "Displays", trailing: "\(report.displays.count) connected") {
            if report.displays.isEmpty { Text("CoreGraphics reports no online displays.").foregroundStyle(p.dim) }
            ForEach(report.displays) { d in
                HStack(spacing: 10) {
                    Image(systemName: d.builtIn ? "laptopcomputer" : "display").frame(width: 20).foregroundStyle(p.accent)
                    Text(d.name).fontWeight(.semibold)
                    if d.main { DisplayBadge(text: "MAIN", color: p.accent) }
                    DisplayBadge(text: d.transport.short.uppercased(), color: p.dim)
                    Spacer()
                    Text(d.mode?.summary ?? "mode unavailable").foregroundStyle(p.dim)
                    severityIcon(d.worstSeverity)
                }.font(.system(size: 12, design: .monospaced))
            }
        }
    }

    @ViewBuilder func severityIcon(_ s: DisplayDiagnosis.Severity?) -> some View {
        switch s {
        case .warning?: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.crit)
        case .caution?: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(p.warn)
        default: Image(systemName: "checkmark.circle").foregroundStyle(p.accent)
        }
    }
}

/// Small capsule label.
struct DisplayBadge: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
    }
}

/// One display: diagnoses, then identity / mode / HDR / connection columns, then the mode list.
struct DisplayCard: View {
    @Environment(\.palette) var p
    var display: DisplayFacts
    var expandModes = false

    var body: some View {
        let d = display
        Panel(title: d.name, trailing: [d.builtIn ? "built-in" : "external", d.main ? "main display" : nil].compactMap { $0 }.joined(separator: " · ")) {
            ForEach(d.diagnoses) { DiagnosisRow(diagnosis: $0) }
            HStack(alignment: .top, spacing: 16) {
                IdentityFacts(display: d).frame(maxWidth: .infinity, alignment: .topLeading)
                ModeFacts(display: d).frame(maxWidth: .infinity, alignment: .topLeading)
                HDRFacts(display: d).frame(maxWidth: .infinity, alignment: .topLeading)
                ConnectionFacts(display: d).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            ModeList(display: d, expanded: expandModes)
        }
    }
}

/// A diagnosis: coloured title, the explanation and what to do.
struct DiagnosisRow: View {
    @Environment(\.palette) var p
    var diagnosis: DisplayDiagnosis

    var body: some View {
        let x = diagnosis
        let color: Color = x.severity == .warning ? p.crit : x.severity == .caution ? p.warn : p.accent
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: x.severity == .info ? "info.circle" : "exclamationmark.triangle.fill").foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(x.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                Text(x.detail).font(.system(size: 11)).foregroundStyle(p.text)
                if let a = x.advice { Text("→ " + a).font(.system(size: 11)).foregroundStyle(p.dim) }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
    }
}
