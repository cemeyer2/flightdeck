import SwiftUI
import FlightDeckCore
// What Changed (Overview): what was installed, updated, removed or reconfigured on this Mac, and when. A summary, the
// notable changes, then a timeline grouped by day with a kind filter and search; each item links to Startup Apps,
// Installed Apps or Checkup where those show it in full. Data from ChangeService (ChangesModel.swift); panels are in
// ChangesPanels.swift.

struct ChangesView: View {
    @Environment(\.palette) var p
    @StateObject private var model: ChangesModel
    @State private var category: ChangeCategory?
    @State private var notableOnly = false
    @State private var query = ""

    init(model: ChangesModel? = nil, category: ChangeCategory? = nil, query: String = "") {
        // Demo mode gets invented data; nothing is read from this Mac.
        _model = StateObject(wrappedValue: model ?? (Demo.isEnabled ? ChangesModel(preview: DemoChanges.report(), demo: true) : ChangesModel()))
        _category = State(initialValue: category); _query = State(initialValue: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            MaybeScroll {
                VStack(alignment: .leading, spacing: 12) {
                    Text(note).font(.caption).foregroundStyle(p.dim)
                    if let r = model.report { content(r) }
                    else { Text("Taking the first inventory…").foregroundStyle(p.dim) }
                }.padding(14)
            }
        }
        .task { await model.check() }
        .onReceive(NotificationCenter.default.publisher(for: ChangeService.didCheck)) { _ in model.reload() }
    }

    var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Kind", selection: $category) {
                Text("All kinds").tag(ChangeCategory?.none)
                Divider()
                ForEach(ChangeCategory.allCases) { Text($0.title).tag(ChangeCategory?.some($0)) }
            }.frame(width: 240)
            TextField("Search: name, path, team ID, signer or reason", text: $query)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            Toggle("Only notable", isOn: $notableOnly)
            if model.checking { ProgressView().controlSize(.small) }
            Spacer()
            Button("Check Now") { Task { await model.check(force: true) } }.disabled(model.checking || model.fixed)
        }
        .font(.system(size: 12)).padding(10)
    }

    var note: String {
        let base = "FlightDeck takes an inventory of what's installed and set to run (launch agents and daemons, system and kernel extensions, profiles, sharing services, apps, Homebrew, macOS) every 15 minutes while it runs and when this page opens, compares it with the last one, and keeps 90 days of changes in Application Support. Read-only: nothing is changed or sent anywhere."
        return model.demo ? "Demo data: an invented week on an invented Mac, nothing about this one. " + base : base
    }

    @ViewBuilder func content(_ r: ChangesReport) -> some View {
        let shown = r.filtered(categories: category.map { [$0] } ?? [], notableOnly: notableOnly, query: query)
        let now = r.lastCheck ?? Date()
        summary(r, now: now)
        NotableChangesPanel(events: r.events.filter { $0.notable && now.timeIntervalSince($0.when) < 30 * 86_400 }) { query = $0 }
        if shown.isEmpty {
            Panel(title: "Timeline") { Text(emptyText(r)).foregroundStyle(p.dim) }
        } else {
            ForEach(ChangesReport.byDay(Array(shown.prefix(400))), id: \.day) { g in ChangeDayPanel(day: g.day, events: g.events, now: now) }
            if shown.count > 400 { Text("Showing the 400 newest changes; filter or search to find older ones.").font(.caption).foregroundStyle(p.dim) }
        }
        if let b = r.baseline {
            Text("Baseline: FlightDeck's first inventory, \(b.formatted(date: .abbreviated, time: .shortened)). Changes before it aren't known.")
                .font(.caption).foregroundStyle(p.dim)
        }
        TrackedPanel(inventory: r.inventory)
    }

    func emptyText(_ r: ChangesReport) -> String {
        if !query.isEmpty { return "No change matches \"\(query)\"." }
        if notableOnly { return "No notable changes." }
        if r.events.isEmpty, let b = r.baseline {
            return "No changes since the baseline was taken (\(b.formatted(date: .abbreviated, time: .shortened))). Installs, updates and new launch agents will appear here."
        }
        return category == nil ? "No changes recorded yet." : "No changes to \(category!.title.lowercased())."
    }

    func summary(_ r: ChangesReport, now: Date) -> some View {
        let week = r.events.filter { now.timeIntervalSince($0.when) < 7 * 86_400 }
        let notable = week.filter(\.notable).count
        let apps = week.filter { $0.category == .app && $0.kind != .removed }.count
        let launch = week.filter { $0.category == .launchItem && $0.kind != .removed }.count
        let os = r.events.first { $0.category == .macOS }
        return Panel(title: "Last 7 days", trailing: r.lastCheck.map { "last check \(changeAgo($0, now: Date()))" }) {
            HStack(spacing: 28) {
                Readout(label: "Changes", value: "\(week.count)", size: 16)
                Readout(label: "Notable", value: "\(notable)", color: notable > 0 ? p.warn : nil, size: 16)
                Readout(label: "Apps added/updated", value: "\(apps)", size: 16)
                Readout(label: "New launch items", value: "\(launch)", size: 16)
                Readout(label: "Last macOS update", value: os.map { $0.when.formatted(date: .abbreviated, time: .omitted) } ?? "none seen", size: 16)
                Spacer()
            }
        }
    }
}

/// "3 min ago", "2 h ago", "Mon 14:05".
func changeAgo(_ d: Date, now: Date) -> String {
    let s = now.timeIntervalSince(d)
    if s < 90 { return "just now" }
    if s < 3600 { return "\(Int(s / 60)) min ago" }
    if s < 86_400 { return "\(Int(s / 3600)) h ago" }
    return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}
