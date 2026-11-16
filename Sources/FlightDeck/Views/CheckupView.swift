import SwiftUI
import FlightDeckCore

// Checkup destination: the health and security checklist from FlightDeckCore's `Checkup`. Checks run off the main
// thread when the page first appears and on Refresh; results are cached in `CheckupModel.shared` so switching away and
// back doesn't rerun them. `softwareupdate --list` is slow and contacts Apple, so it only runs on its own button.

/// Cached checklist, shared across window re-creations of the view.
@MainActor
final class CheckupModel: ObservableObject {
    static let shared = CheckupModel()
    @Published var results: [CheckResult] = []
    @Published var running = false
    @Published var checkedAt: Date?
    @Published var checkingUpdates = false
    /// Result of the last Check Now (`softwareupdate --list`), fed back into the pending-updates row on every run.
    private var liveUpdates: [String]?
    private var liveError: String?

    /// Swap history is read from the black box's coarse tier (24 h, one frame every 10 s): only the swap figure is kept.
    func run(engine: Engine) {
        guard !running else { return }
        running = true
        Task {
            let trace = await engine.readBlackBox(.coarse, from: Date().addingTimeInterval(-86_400))
            let swap: [(Date, Double)] = (trace?.frames ?? []).compactMap { f in f.memory.swapUsed.value.map { (f.time, $0) } }
            let live = liveUpdates, err = liveError
            let r = await Task.detached(priority: .userInitiated) { Checkup.run(swapHistory: swap, liveUpdates: live, liveUpdateError: err) }.value
            results = r; checkedAt = Date(); running = false
        }
    }

    func checkUpdates(engine: Engine) {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { Checkup.softwareUpdateCheck() }.value
            liveUpdates = r.updates; liveError = r.error
            checkingUpdates = false
            run(engine: engine)
        }
    }
}

struct CheckupView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.palette) var p
    @ObservedObject var model = CheckupModel.shared

    var body: some View {
        if Demo.isEnabled {
            DemoUnavailable(what: "Checkup reads this Mac's security settings")
        } else {
            MaybeScroll {
                VStack(spacing: 12) {
                    header
                    let groups = model.results.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
                    ForEach(groups, id: \.self) { g in
                        Panel(title: g) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(model.results.filter { $0.group == g }) { r in CheckRow(result: r, model: model) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if model.running && model.results.isEmpty { ProgressView("Running checks…").padding(30) }
                }.padding(16)
            }
            .onAppear { if model.results.isEmpty { model.run(engine: engine) } }
        }
    }

    var header: some View {
        HStack(spacing: 14) {
            let n = { (s: CheckResult.Status) in model.results.filter { $0.status == s }.count }
            Label("\(n(.pass)) OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Label("\(n(.attention)) need attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Label("\(n(.unknown)) unknown", systemImage: "questionmark.circle").foregroundStyle(p.dim)
            Spacer()
            if let t = model.checkedAt { Text("checked " + t.formatted(date: .omitted, time: .shortened)).foregroundStyle(p.dim) }
            if model.running { ProgressView().controlSize(.small) }
            Button("Refresh") { model.run(engine: engine) }.disabled(model.running)
        }.font(.system(size: 12, design: .monospaced))
    }
}

/// One checklist row: status icon, title and value, explanation, and buttons for where to fix it.
struct CheckRow: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.palette) var p
    var result: CheckResult
    @ObservedObject var model: CheckupModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 15)).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(result.title).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(p.text)
                    Spacer()
                    Text(result.value).font(.system(size: 12, design: .monospaced)).foregroundStyle(color)
                }
                Text(result.detail).font(.system(size: 11)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                HStack(spacing: 8) {
                    ForEach(result.fixes, id: \.self) { f in
                        switch f {
                        case .settings(let label, let url):
                            Button(label) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
                        case .app(let label, let dest):
                            Button(label) { engine.navigationRequest = dest }
                        }
                    }
                    if result.id == "pending" {
                        Button(model.checkingUpdates ? "Checking…" : "Check Now") { model.checkUpdates(engine: engine) }
                            .disabled(model.checkingUpdates)
                            .help("Runs softwareupdate --list, which asks Apple's servers (can take a minute)")
                    }
                }.controlSize(.small).padding(.top, 2)
            }
        }
    }

    var icon: String {
        switch result.status { case .pass: "checkmark.circle.fill"; case .attention: "exclamationmark.triangle.fill"; case .unknown: "questionmark.circle" }
    }
    var color: Color {
        switch result.status { case .pass: .green; case .attention: .orange; case .unknown: p.dim }
    }
}

/// Shown instead of pages that read the real machine while demo mode is on, so screenshots can't leak its details.
struct DemoUnavailable: View {
    @Environment(\.palette) var p
    var what: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash").font(.system(size: 28)).foregroundStyle(p.dim)
            Text("Not available in demo mode").font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(p.text)
            Text("\(what), so it is hidden while demo mode shows invented data.").font(.system(size: 11)).foregroundStyle(p.dim)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}
