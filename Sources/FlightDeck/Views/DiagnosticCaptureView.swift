// The "Capture Diagnostics…" sheet: explains what will be collected (and that it can contain personal information),
// asks where to save it, runs DiagnosticCapture on a background task with live per-step progress, and finishes with
// what was included and a Show in Finder button. Disabled in demo mode.
import SwiftUI
import UniformTypeIdentifiers
import FlightDeckCore

struct DiagnosticCaptureView: View {
    enum Phase { case intro, running, finished(URL) }
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @Environment(\.dismiss) private var dismiss
    @AppStorage("diagnosticsZip") private var zip = true
    /// Initial values are settable so UIBench can render each phase.
    @State var phase: Phase = .intro
    @State var steps: [DiagnosticCapture.Step] = []

    /// What would be sampled right now (shown in the intro so the user knows which processes are involved).
    var targets: [DiagnosticCapture.Target] { DiagnosticCapture.targets(e.liveSnapshot?.processes ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "stethoscope").font(.title2).foregroundStyle(p.accent)
                Text("Capture Diagnostics").font(.title2.bold())
            }
            privacyNote
            if !PowerTools.captureAvailable {
                Text("Not available in demo mode: a capture reads this Mac's real processes and logs.").foregroundStyle(p.dim)
            }
            switch phase {
            case .intro: intro
            case .running, .finished: progressList
            }
            HStack {
                if case .finished(let url) = phase {
                    Text(url.lastPathComponent).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                switch phase {
                case .intro:
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Choose Location and Capture…") { start() }.keyboardShortcut(.defaultAction).disabled(!PowerTools.captureAvailable)
                case .running:
                    ProgressView().controlSize(.small)
                    Text("Capturing… this takes about 15 seconds").foregroundStyle(p.dim)
                case .finished(let url):
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20).frame(width: 600)
        .background(p.background)
    }

    var privacyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.warn)
            Text("The capture can contain personal information: file paths with your user name, your computer name, app and document names, process arguments and log messages. Review the files before you share them.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(p.warn.opacity(0.12)))
    }

    var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("It will include:").font(.headline)
            ForEach(DiagnosticCapture.steps(.init(blackBox: nil, summary: "", targets: targets, reportsSince: Date()))) { s in
                Label(s.title, systemImage: "doc").foregroundStyle(p.text)
            }
            let t = targets
            Text(t.isEmpty ? "No processes of yours are busy or hung, so no call stacks will be sampled."
                 : "Processes to sample: " + t.map { "\($0.name) (\($0.reason))" }.joined(separator: ", ") + ".")
                .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            Text("Only your own processes are sampled. Serial number and hardware UUID are left out of the summary. Nothing is sent anywhere.")
                .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            Toggle("Compress as a .zip file", isOn: $zip)
        }
    }

    var progressList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon(s.state).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title)
                        if let d = s.detail { Text(d).font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }
    }

    @ViewBuilder func icon(_ st: DiagnosticCapture.Step.State) -> some View {
        switch st {
        case .pending: Image(systemName: "circle").foregroundStyle(p.dim)
        case .running: Image(systemName: "circle.dotted").foregroundStyle(p.accent)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(p.accent)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(p.dim)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(p.crit)
        }
    }

    /// Asks for a location, gathers the inputs that live on the main actor (black box read on its queue, latest sample,
    /// findings), then runs the capture detached. Progress callbacks hop back to the main actor to update the list.
    func start() {
        guard PowerTools.captureAvailable else { return }
        let panel = NSSavePanel()
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "FlightDeck Diagnostics \(df.string(from: Date()))"
        panel.canCreateDirectories = true
        panel.message = "Choose where to save the diagnostics. Review them before sharing: they can contain personal information."
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        // Never write into (or delete) something that already exists: pick a fresh name next to it instead.
        let folder = Self.unique(picked.pathExtension == "zip" ? picked.deletingPathExtension() : picked, zip: zip)
        let snapshot = e.liveSnapshot
        let findings = e.liveFindings + e.reportFindings + e.sleepFindings
        let targets = DiagnosticCapture.targets(snapshot?.processes ?? [])
        let zip = self.zip
        steps = DiagnosticCapture.steps(.init(blackBox: nil, summary: "", targets: targets, reportsSince: Date()))
        phase = .running
        Task {
            let bb = e.blackBoxEnabled ? await e.readBlackBox(.fine, from: Date().addingTimeInterval(-600)) : nil
            let result = await Task.detached(priority: .userInitiated) { () -> URL in
                // System information runs csrutil and enumerates volumes, so it is collected here, off the main thread.
                let summary = DiagnosticCapture.summaryText(snapshot: snapshot, findings: findings, info: SystemInfo.collect())
                let input = DiagnosticCapture.Input(blackBox: bb, summary: summary, targets: targets, reportsSince: Date().addingTimeInterval(-86_400))
                return DiagnosticCapture.run(input, into: folder, zip: zip) { step in
                    Task { @MainActor in
                        if let i = steps.firstIndex(where: { $0.id == step.id }) { steps[i] = step }
                    }
                }.url
            }.value
            phase = .finished(result)
        }
    }

    /// `url` (or url.zip) if nothing exists there, else "<name> 2", "<name> 3", …
    static func unique(_ url: URL, zip: Bool) -> URL {
        let fm = FileManager.default
        func taken(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) || (zip && fm.fileExists(atPath: u.path + ".zip")) }
        guard taken(url) else { return url }
        let base = url.lastPathComponent, dir = url.deletingLastPathComponent()
        for n in 2... { let u = dir.appendingPathComponent("\(base) \(n)"); if !taken(u) { return u } }
        return url
    }
}
