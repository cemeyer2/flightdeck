// "Destinations" (Network section): who each app talks to. Apps, busiest first, each with its destinations (grouped by
// registrable domain of the reverse-DNS name, or by IP), bytes today / 7 / 30 days, connections and first/last seen.
// New destinations (first contact in 24 h) and unusual volume are badged and summarised at the top; the search field
// answers "which apps talked to X". Every name is labelled with its source, and the note says what nettop misses.
import SwiftUI
import FlightDeckCore

struct DestinationsView: View {
    @ObservedObject var model: DestinationsModel
    @Environment(\.palette) var p
    @AppStorage("destinationsRange") private var range: DestinationRange = .week
    @State private var query = ""
    @State private var onlyFlagged = false
    /// Apps the user opened or closed; others follow the default (the first three open, all open while searching).
    @State private var toggled: Set<String> = []
    @State private var confirmClear = false
    /// Pins the range (UIBench renders), leaving the saved choice alone.
    var fixedRange: DestinationRange?
    @MainActor init(model: DestinationsModel? = nil, range: DestinationRange? = nil, query: String = "") {
        self.model = model ?? .shared; fixedRange = range; _query = State(initialValue: query)
    }

    var body: some View {
        let range = fixedRange ?? self.range
        let searched = DestinationReport.search(model.apps, query)
        let shown = searched.compactMap { a -> AppDestinations? in
            var a = a
            if onlyFlagged { a.destinations = a.destinations.filter { $0.isNew || $0.unusual } }
            a.destinations = a.destinations.filter { range.bytes($0) > 0 || range == .month || $0.isNew }
            return a.destinations.isEmpty ? nil : a
        }.sorted { range.bytes($0) != range.bytes($1) ? range.bytes($0) > range.bytes($1) : $0.name < $1.name }
        VStack(spacing: 0) {
            toolbar
            MaybeScroll {
                VStack(alignment: .leading, spacing: 12) {
                    Text(note).font(.caption).foregroundStyle(p.dim)
                    summary(model.apps)
                    flagged(model.apps)
                    if shown.isEmpty {
                        Panel(title: "Apps") { Text(emptyText).foregroundStyle(p.dim) }
                    }
                    ForEach(Array(shown.prefix(60).enumerated()), id: \.element.id) { i, a in appPanel(a, index: i, range: range) }
                    if shown.count > 60 { Text("Showing the 60 busiest apps; search to find others.").font(.caption).foregroundStyle(p.dim) }
                }.padding(14)
            }
        }
        .onAppear { model.refresh() }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
        .confirmationDialog("Clear the Destinations history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("Deletes every recorded destination and the list of destinations seen before, so the next contacts count as first contacts after a day of learning.")
        }
    }

    var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $range) { ForEach(DestinationRange.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            TextField("Which apps talked to… (domain, host or IP)", text: $query)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            Toggle("Only new or unusual", isOn: $onlyFlagged)
            Spacer()
            Button("Clear History…") { confirmClear = true }.disabled(model.apps.isEmpty || model.preview)
        }.padding(10)
    }

    var note: String {
        let base = "Traffic per app and remote host from macOS's nettop (the same connection counters as Network by app), recorded on this Mac and kept for \(DestinationStore.retentionDays) days in Application Support; nothing is sent anywhere. Names come from reverse DNS (the IP owner's PTR record, often a hosting or CDN provider, not verified) or are missing (\"no name\"); which name an app actually looked up isn't visible to FlightDeck. Connections that open and close between two samples, and bytes after the last sample before a connection closes, are missed."
        if model.preview { return "Demo data: invented apps and destinations, nothing about this Mac. " + base }
        guard let since = model.since else { return base + " Nothing recorded yet." }
        return base + " Recording since \(since.formatted(date: .abbreviated, time: .shortened)); \(model.daysRecorded) day\(model.daysRecorded == 1 ? "" : "s") with data."
    }

    var emptyText: String {
        if !query.isEmpty { return "No app talked to anything matching \"\(query)\" in the last \(DestinationStore.retentionDays) days." }
        if onlyFlagged { return "No new destinations or unusual volume." }
        return model.built == nil ? "Loading…" : "No traffic recorded in this range yet."
    }

    @ViewBuilder func summary(_ apps: [AppDestinations]) -> some View {
        let dests = apps.reduce(0) { $0 + $1.destinations.count }
        let new = apps.reduce(0) { $0 + $1.newCount }, unusual = apps.reduce(0) { $0 + $1.unusualCount }
        let local = apps.reduce(0) { $0 + $1.destinations.filter { $0.scope.isLocal }.count }
        HStack(spacing: 12) {
            stat("APPS · 30 DAYS", "\(apps.count)")
            stat("DESTINATIONS · 30 DAYS", "\(dests)", sub: "\(local) on the local network")
            stat("NEW (24 H)", "\(new)", lit: new > 0)
            stat("UNUSUAL TODAY", "\(unusual)", lit: unusual > 0, warn: true)
        }
    }

    func stat(_ title: String, _ value: String, sub: String? = nil, lit: Bool = false, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.meterLabel).foregroundStyle(p.dim)
            Text(value).font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(lit ? (warn ? p.warn : p.accent) : p.text)
            if let sub { Text(sub).font(.caption).foregroundStyle(p.dim) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(PanelSurface())
    }

    /// New destinations and unusual volume across all apps, newest first.
    @ViewBuilder func flagged(_ apps: [AppDestinations]) -> some View {
        let items = apps.flatMap { a in a.destinations.filter { $0.isNew || $0.unusual }.map { (a, $0) } }
            .sorted { $0.1.first > $1.1.first }
        if !items.isEmpty {
            Panel(title: "Worth a look", trailing: "\(items.count) · click to search") {
                ForEach(items.prefix(12), id: \.1.id) { a, d in
                    Button { query = d.isOther ? a.name : d.id } label: {
                        HStack(spacing: 8) {
                            DestinationBadge(text: d.isNew ? "NEW" : "UNUSUAL", color: d.isNew ? p.accent : p.warn).frame(width: 64, alignment: .leading)
                            Text(a.name).fontWeight(.semibold).frame(width: 170, alignment: .leading).lineLimit(1)
                            Text("→ \(d.label)").lineLimit(1)
                            Text(d.isNew ? "first contact \(DestinationTable.when(d.first)) · \(Fmt.bytes(d.month))"
                                         : "\(Fmt.bytes(d.today)) today vs. \(Fmt.bytes(d.typicalDay))/day typical").foregroundStyle(p.dim)
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).font(.system(size: 11, design: .monospaced))
                }
            }
        }
    }

    func isOpen(_ a: AppDestinations, _ index: Int) -> Bool {
        let byDefault = index < 3 || !query.isEmpty || onlyFlagged
        return toggled.contains(a.id) ? !byDefault : byDefault
    }

    func appPanel(_ a: AppDestinations, index: Int, range: DestinationRange) -> some View {
        let open = isOpen(a, index)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if toggled.contains(a.id) { toggled.remove(a.id) } else { toggled.insert(a.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").foregroundStyle(p.dim).frame(width: 12)
                    AppIcon(path: a.id.hasPrefix("proc:") ? "" : a.id + "/").frame(width: 16, height: 16)
                    Text(a.name).font(.system(size: 13, weight: .semibold))
                    if a.newCount > 0 { DestinationBadge(text: "\(a.newCount) NEW", color: p.accent) }
                    if a.unusualCount > 0 { DestinationBadge(text: "\(a.unusualCount) UNUSUAL", color: p.warn) }
                    Spacer()
                    Text("\(a.destinations.count) destination\(a.destinations.count == 1 ? "" : "s") · \(Fmt.bytes(range.bytes(a))) \(range.rawValue.lowercased())")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open { DestinationTable(app: a, range: range) }
        }
        .padding(12).background(PanelSurface())
    }
}
