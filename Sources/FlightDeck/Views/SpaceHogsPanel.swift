import SwiftUI
import FlightDeckCore

// Disk Space › "What's using my disk", second panel: the known space hogs. Nothing is measured until Analyze is
// pressed (reading Downloads, Mail or Messages makes macOS ask for access). Each row expands to say where the space
// is, what it is, what removing it does, and offers the one safe cleanup FlightDeck has for it.

struct SpaceHogsPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: StorageModel

    var trailing: String? {
        if model.analyzing { return "measuring \(min(model.current + 1, model.catalog.count)) of \(model.catalog.count)…" }
        let known = model.results.compactMap(\.total)
        return model.results.isEmpty ? nil : "\(Fmt.storage(known.reduce(0, +))) in \(known.count) readable categories"
    }

    var body: some View {
        Panel(title: "Known space hogs", trailing: trailing) {
            header
            if !model.results.isEmpty || model.analyzing {
                let top = model.results.compactMap(\.total).max() ?? 1
                VStack(spacing: 2) {
                    ForEach(model.catalog) { c in
                        if let r = model.result(c.id) {
                            HogRow(model: model, r: r, top: top)
                        } else if model.analyzing {
                            pendingRow(c, active: model.catalog.firstIndex(of: c) == model.current)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder var header: some View {
        if model.analyzing {
            HStack(spacing: 10) {
                ProgressView(value: Double(model.current), total: Double(model.catalog.count)).frame(maxWidth: 320)
                Text(model.catalog[min(model.current, model.catalog.count - 1)].title).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.dim)
                Spacer()
                Button("Cancel") { model.cancel() }
            }
        } else if model.results.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Not analyzed yet.").font(.system(size: 13, weight: .semibold))
                Text("Analyze measures the \(model.catalog.count) places below that usually fill a Mac: caches, logs, the Trash, old downloads, device backups, Xcode and simulator data, container disk images, package-manager caches, Mail and Messages attachments, the Photos library, macOS installers and virtual machines. It only reads; nothing is removed unless you choose a cleanup and confirm it.")
                    .font(.system(size: 11)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                Text("macOS may ask you to allow FlightDeck to access some folders (Downloads, Pictures, Mail, Messages, the Trash, and other apps' data such as Docker's). Any you don't allow are shown as \"not readable\", never as empty.")
                    .font(.system(size: 11)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                Button("Analyze") { model.analyze() }.keyboardShortcut(.defaultAction)
            }
        } else {
            HStack {
                Text(model.demo ? "Demo data: invented sizes; cleanups are disabled." : "Sizes are allocated space on disk, as Finder counts it. Click a row for details and cleanup.")
                    .font(.system(size: 11)).foregroundStyle(p.dim)
                Spacer()
                if let w = model.working { ProgressView().controlSize(.small); Text(w).font(.system(size: 11)).foregroundStyle(p.dim) }
                Button("Analyze Again") { model.analyze() }.disabled(model.working != nil)
            }
        }
        if let rep = model.report {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("CLEANUP · \(rep.title.uppercased())").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(p.accent)
                    Spacer()
                    Button { model.report = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                ForEach(rep.lines, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 6).stroke(p.accent.opacity(0.5)))
        }
    }

    func pendingRow(_ c: SpaceHogCategory, active: Bool) -> some View {
        HStack {
            Image(systemName: c.symbol).foregroundStyle(p.dim).frame(width: 20)
            Text(c.title).foregroundStyle(p.dim)
            Spacer()
            Text(active ? "measuring…" : "waiting").foregroundStyle(p.dim)
        }
        .font(.system(size: 12, design: .monospaced)).padding(.vertical, 4)
    }
}

/// One analyzed category: a summary line (size, safety, meter) and, when expanded, the explanation and actions.
struct HogRow: View {
    @Environment(\.palette) var p
    @ObservedObject var model: StorageModel
    var r: HogResult
    var top: UInt64
    var open: Bool { model.expanded.contains(r.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(p.dim).frame(width: 10)
                Image(systemName: r.category.symbol).foregroundStyle(p.accent).frame(width: 20)
                Text(r.category.title).frame(width: 230, alignment: .leading)
                // Relative to the largest row, so warning colours would mislead: one colour. Absent is a real empty meter;
                // unreadable is the meter's "unavailable" state.
                VFDMeter(fraction: r.isAbsent ? 0 : r.total.map { Double($0) / Double(max(top, 1)) }, segments: 30, color: p.accent, height: 8)
                Text(StorageModel.label(r)).frame(width: 130, alignment: .trailing).foregroundStyle(r.total == nil ? p.dim : p.text)
                Text(r.category.safety.label).font(.system(size: 10, design: .monospaced)).foregroundStyle(safetyColor)
                    .frame(width: 190, alignment: .leading)
            }
            .font(.system(size: 12, design: .monospaced))
            .contentShape(Rectangle())
            .onTapGesture { if open { model.expanded.remove(r.id) } else { model.expanded.insert(r.id) } }
            if open { HogDetail(model: model, r: r).padding(.leading, 40) }
        }
        .padding(.vertical, 4)
    }

    var safetyColor: Color {
        switch r.category.safety { case .safe: p.accent; case .safeWithCost: p.accent2; case .yourData: p.warn }
    }
}
