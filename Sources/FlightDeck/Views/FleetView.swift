import SwiftUI
import FlightDeckCore
// Fleet destination: your other Macs running FlightDeck. Paired Macs as cards (vital signs, sparklines, worst finding),
// Macs nearby that aren't paired yet, and a read-only detail panel for the selected Mac. Data from FleetModel; the
// sharing side lives in FleetService and Settings › Network › Fleet.

struct FleetView: View {
    @Environment(\.palette) var p
    @ObservedObject var model: FleetModel
    @AppStorage(FleetService.sharingKey) private var sharing = false
    @State private var pairing: FleetAdvert?

    init(model: FleetModel? = nil) { self.model = model ?? FleetModel.shared }

    static let columns = 3

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Your other Macs running FlightDeck: their vital signs and incidents, read-only.").foregroundStyle(p.dim)
                    Spacer()
                    Text(sharingNote).foregroundStyle(p.dim)
                }.font(.system(size: 12))
                if model.hosts.isEmpty && model.unpaired.isEmpty { empty } else { grid }
                if let id = model.selected, let h = model.hosts.first(where: { $0.id == id }) {
                    FleetDetail(host: h) { model.forget(id) }
                }
            }.padding(16)
        }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
        .sheet(item: Binding(get: { pairing.map(PairTarget.init) }, set: { pairing = $0?.advert })) { t in
            FleetPairSheet(advert: t.advert, model: model).environment(\.palette, p)
        }
    }

    var sharingNote: String {
        Demo.isEnabled ? "Demo data" : (sharing ? "This Mac is shared" : "This Mac isn't shared (Settings › Network › Fleet)")
    }

    /// Cards in rows (not a lazy grid, so off-screen renders lay out the same).
    var grid: some View {
        let items: [AnyView] = model.hosts.map { h in
            AnyView(FleetHostCard(host: h, selected: model.selected == h.id)
                .onTapGesture { model.selected = model.selected == h.id ? nil : h.id })
        } + model.unpaired.map { a in AnyView(FleetNearbyCard(advert: a) { pairing = a }) }
        let rows = stride(from: 0, to: items.count, by: Self.columns).map { Array(items[$0..<min($0 + Self.columns, items.count)]) }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(rows[r].indices, id: \.self) { i in rows[r][i].frame(maxWidth: .infinity) }
                    ForEach(rows[r].count..<Self.columns, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }

    var empty: some View {
        Panel(title: "No Macs yet") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Other Macs on this network running FlightDeck appear here once they share themselves.")
                    .font(.system(size: 13))
                Text("1. On the other Mac, open FlightDeck Settings › Network › Fleet and turn on Share this Mac with my other Macs.")
                Text("2. Click Pair a Mac there. A 6-digit code appears.")
                Text("3. Its card appears here; click Pair… and enter the code.")
                Text("Sharing is off by default and each Mac decides for itself. Paired Macs see only vital signs, findings and a 30-minute history: never processes, file names, user names or network destinations, and they can't change anything.")
                    .foregroundStyle(p.dim)
            }.font(.system(size: 12))
        }
    }
}

/// `sheet(item:)` needs an Identifiable.
struct PairTarget: Identifiable { var advert: FleetAdvert; var id: String { advert.name } }

/// Enter the code shown on the other Mac.
struct FleetPairSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) var p
    var advert: FleetAdvert
    @ObservedObject var model: FleetModel
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair with \(advert.name)").font(.headline)
            Text("On \(advert.name), open FlightDeck Settings › Network › Fleet, click Pair a Mac, and type the code it shows.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("6-digit code", text: $code).font(.system(size: 20, design: .monospaced)).textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if let e = model.pairError { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                if model.pairingWith != nil { ProgressView().controlSize(.small); Text("Pairing…").font(.caption) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Pair", action: submit).keyboardShortcut(.defaultAction)
                    .disabled(FleetCrypto.digits(code) == nil || model.pairingWith != nil)
            }
        }
        .padding(20).frame(width: 380)
        .onAppear { model.pairError = nil }
    }

    func submit() {
        guard FleetCrypto.digits(code) != nil else { return }
        Task { if await model.pair(advert, code: code) { dismiss() } }
    }
}
