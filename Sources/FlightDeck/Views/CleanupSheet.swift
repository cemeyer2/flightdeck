import SwiftUI
import FlightDeckCore

// Disk Space › space hogs: a row's expanded detail (where, what, what removing it does, the largest items, actions)
// and the confirmation sheet every cleanup goes through, listing exactly what will go and the total.

struct HogDetail: View {
    @Environment(\.palette) var p
    @ObservedObject var model: StorageModel
    var r: HogResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            fact("WHAT IT IS", r.category.whatItIs)
            fact("IF YOU REMOVE IT", r.category.ifRemoved)
            fact("WHERE", r.locations.isEmpty ? r.category.paths.joined(separator: "\n") : r.locations.map { "\($0.path)  \(sizeText($0.size))" }.joined(separator: "\n"), mono: true)
            ForEach(r.unreadable, id: \.path) { u in
                fact("NOT READABLE", "\((u.path as NSString).lastPathComponent): \(u.reason)")
            }
            if r.isPartial && r.unreadable.isEmpty {
                fact("PARTIAL", "Some items inside couldn't be read, so the size is a lower bound.")
            }
            ForEach(r.notes, id: \.self) { fact("TOOLS", $0, mono: true) }
            let items = r.locations.flatMap(\.items).sorted { ($0.size.bytes ?? 0) > ($1.size.bytes ?? 0) }
            if !items.isEmpty {
                Text("LARGEST INSIDE").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(p.dim)
                ForEach(items.prefix(6)) { i in
                    HStack {
                        Text(i.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let d = i.added { Text(Self.age(d)).foregroundStyle(p.dim) }
                        Text(sizeText(i.size)).frame(width: 110, alignment: .trailing)
                    }.font(.system(size: 11, design: .monospaced))
                }
                if items.count > 6 { Text("…and \(items.count - 6) more").font(.system(size: 11)).foregroundStyle(p.dim) }
            }
            actions
        }
    }

    @ViewBuilder var actions: some View {
        HStack(spacing: 8) {
            if let first = r.locations.first(where: { $0.size != .missing }) {
                Button("Reveal in Finder") { model.reveal(first.path) }.disabled(model.demo)
            }
            switch r.category.cleanup {
            case .manual(let advice):
                Text(advice).font(.system(size: 11)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            case .trashContents, .trashOlderThan, .trashItems:
                let plan = CleanupPlanner.plan(r)
                Button(plan.items.isEmpty ? "Nothing to move" : "Move \(plan.items.count) item\(plan.items.count == 1 ? "" : "s") to Trash…") { model.prepare(r) }
                    .disabled(model.demo || plan.items.isEmpty || model.working != nil)
            case .emptyTrashViaFinder:
                Button("Empty Trash…") { model.prepare(r) }.disabled(model.demo || model.working != nil)
            case .simctlDeleteUnavailable:
                Button("Delete Unavailable Simulators…") { model.prepare(r) }.disabled(model.demo || model.working != nil)
            case .brewCleanup:
                Button("brew cleanup…") { model.prepare(r) }.disabled(model.demo || model.working != nil)
            }
        }
        .controlSize(.small)
        .sheet(item: pendingBinding) { CleanupConfirmSheet(model: model, pending: $0, categoryID: r.id) }
    }

    /// The sheet only belongs to the row whose cleanup is pending.
    var pendingBinding: Binding<PendingCleanup?> {
        Binding(get: { model.pending.flatMap { owns($0) ? $0 : nil } }, set: { model.pending = $0 })
    }
    func owns(_ p: PendingCleanup) -> Bool {
        switch p {
        case .trash(let plan): plan.category.id == r.id
        case .emptyTrash: r.category.cleanup == .emptyTrashViaFinder
        case .simctl: r.category.cleanup == .simctlDeleteUnavailable
        case .brew: r.category.cleanup == .brewCleanup
        }
    }

    func fact(_ label: String, _ text: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(p.dim).frame(width: 110, alignment: .leading)
            Text(text).font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11)).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    func sizeText(_ s: SizeResult) -> String {
        switch s {
        case .size(let b, let u): (u > 0 ? "≥ " : "") + Fmt.storage(b)
        case .notReadable: "not readable"
        case .missing: "not present"
        }
    }

    static func age(_ d: Date) -> String {
        let days = Int(-d.timeIntervalSinceNow / 86_400)
        return days < 1 ? "today" : days == 1 ? "1 day old" : "\(days) days old"
    }
}

/// Confirmation for one cleanup: what goes, the total, and the button that does it.
struct CleanupConfirmSheet: View {
    @Environment(\.palette) var p
    @Environment(\.dismiss) var dismiss
    @ObservedObject var model: StorageModel
    var pending: PendingCleanup
    var categoryID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(explanation).font(.system(size: 12)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        HStack {
                            Text(l.0).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            Text(l.1).foregroundStyle(p.dim)
                        }.font(.system(size: 11, design: .monospaced))
                    }
                }
            }.frame(minHeight: 120, maxHeight: 320)
            HStack {
                Text(totalText).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Button("Cancel") { model.pending = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) { model.confirm(pending, categoryID: categoryID); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(isEmpty)
            }
        }
        .padding(18).frame(width: 620)
    }

    var title: String {
        switch pending {
        case .trash(let plan): "Move \(plan.items.count) item\(plan.items.count == 1 ? "" : "s") from \(plan.category.title) to the Trash?"
        case .emptyTrash: "Empty the Trash?"
        case .simctl(let d): "Delete \(d.count) unavailable simulator\(d.count == 1 ? "" : "s")?"
        case .brew: "Run brew cleanup?"
        }
    }
    var explanation: String {
        switch pending {
        case .trash(let plan):
            "These items move to the Trash; nothing is deleted. You can put them back from the Trash until it's emptied, and the space is freed only then."
                + (plan.refused.isEmpty ? "" : " \(plan.refused.count) item\(plan.refused.count == 1 ? " is" : "s are") left alone because \(plan.refused.count == 1 ? "it isn't" : "they aren't") safe to move (\(plan.refused[0].reason)).")
        case .emptyTrash: "Finder will permanently delete everything in the Trash, exactly as Finder › Empty Trash does. This can't be undone. macOS may ask whether FlightDeck may control Finder."
        case .simctl: "`simctl delete unavailable` removes these simulators, whose runtime is no longer installed, with their apps and data. Available simulators are not touched."
        case .brew: "This is brew's own dry run (`brew cleanup -n`): it lists exactly what `brew cleanup` will delete. Homebrew does the deleting."
        }
    }
    var lines: [(String, String)] {
        switch pending {
        case .trash(let plan): plan.items.map { ($0.path, $0.size.bytes.map { Fmt.storage($0) } ?? "size unknown") }
        case .emptyTrash(let k): [("~/.Trash", k.map { Fmt.storage($0) } ?? "size not readable")]
        case .simctl(let d): d.map { ("\($0.name) · \($0.runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: ""))", $0.udid) }
        case .brew(let out, let paths, _): paths.isEmpty ? out.split(whereSeparator: \.isNewline).map { (String($0), "") } : paths.map { ($0, "") }
        }
    }
    var totalText: String {
        switch pending {
        case .trash(let plan): "Total: \(Fmt.storage(plan.total))" + (plan.unknownSizes > 0 ? " + \(plan.unknownSizes) of unknown size" : "")
        case .emptyTrash(let k): k.map { "Total: \(Fmt.storage($0))" } ?? "Total: unknown (the Trash isn't readable)"
        case .simctl(let d): "\(d.count) simulator\(d.count == 1 ? "" : "s")"
        case .brew(_, _, let est): est.map { "brew estimates \($0)" } ?? "brew gave no estimate"
        }
    }
    var action: String {
        switch pending { case .trash: "Move to Trash"; case .emptyTrash: "Empty Trash"; case .simctl: "Delete"; case .brew: "Run brew cleanup" }
    }
    var isEmpty: Bool {
        switch pending {
        case .trash(let plan): plan.items.isEmpty
        case .simctl(let d): d.isEmpty
        case .brew(_, let paths, _): paths.isEmpty
        case .emptyTrash: false
        }
    }
}
