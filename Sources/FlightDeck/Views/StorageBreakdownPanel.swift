import SwiftUI
import FlightDeckCore

// Disk Space › "What's using my disk", top panel: the startup disk's APFS container as one stacked bar, like Storage
// settings, but with each part named for what it really is (macOS's "System Data" is mostly the Data volume's caches,
// snapshots and app support files). Below it, the local Time Machine snapshots, whose sizes macOS doesn't report
// without root.

struct StorageBreakdownPanel: View {
    @Environment(\.palette) var p
    @ObservedObject var model: StorageModel

    var body: some View {
        switch model.breakdown {
        case nil:
            Panel(title: "Startup disk", trailing: model.loadingBreakdown ? "reading…" : nil) {
                Text("Reading the startup disk's layout from diskutil…").font(.system(size: 12)).foregroundStyle(p.dim)
            }
        case .failure(let e)?:
            Panel(title: "Startup disk", trailing: "unknown") {
                Text("The breakdown isn't available: \(e.reason)").font(.system(size: 12)).foregroundStyle(p.dim)
            }
        case .success(let b)?:
            Panel(title: "Startup disk", trailing: "\(b.volumeName ?? "Startup disk") · APFS container \(b.container.reference) · \(Fmt.storage(b.container.capacity))") {
                content(b)
            }
        }
    }

    @ViewBuilder func content(_ b: StorageBreakdown) -> some View {
        let segs = b.segments
        let used = b.container.capacity - min(b.container.free, b.container.capacity)
        HStack(alignment: .firstTextBaseline) {
            Text(Fmt.storage(used)).font(.system(size: 22, weight: .semibold, design: .monospaced)).foregroundStyle(p.text)
            Text("used").font(.system(size: 12, design: .monospaced)).foregroundStyle(p.dim)
            Spacer()
            Text(b.purgeable.map { "\(Fmt.storage(b.container.free)) free + \(Fmt.storage($0)) purgeable" } ?? "\(Fmt.storage(b.container.free)) free · purgeable unknown")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(p.dim)
        }
        StackedBar(segments: segs, total: b.container.capacity, color: color)
            .frame(height: 22)
        // Legend: every part with its size and a one-line explanation.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(segs) { s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(color(s.kind)).frame(width: 10, height: 10)
                    Text(s.title).font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 130, alignment: .leading)
                    Text(Fmt.storage(s.bytes)).font(.system(size: 12, design: .monospaced)).frame(width: 90, alignment: .trailing)
                    Text(s.explanation).font(.system(size: 11)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            if b.purgeable == nil {
                Text("Purgeable: unknown. macOS didn't report \"available for important usage\" for the startup volume, so it can't be told apart from your data.")
                    .font(.system(size: 11)).foregroundStyle(p.dim)
            }
        }
        Divider().overlay(p.grid)
        snapshots(b)
    }

    @ViewBuilder func snapshots(_ b: StorageBreakdown) -> some View {
        let tm = b.timeMachineSnapshots
        let other = (b.snapshots ?? []).count - tm.count
        VStack(alignment: .leading, spacing: 4) {
            Text("LOCAL TIME MACHINE SNAPSHOTS").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(p.dim)
            if let note = b.snapshotNote {
                Text("Unknown: \(note)").font(.system(size: 11)).foregroundStyle(p.dim)
            } else if tm.isEmpty {
                Text("None on the startup disk.").font(.system(size: 12, design: .monospaced))
            } else {
                let f = Self.dateFormat
                Text(tm.map { $0.date.map(f.string) ?? $0.name }.joined(separator: " · ")).font(.system(size: 12, design: .monospaced))
            }
            Text("Their sizes are unknown: macOS doesn't report how much space a snapshot holds without administrator rights. Time Machine makes them hourly and deletes them after 24 hours or when space runs low; their space is part of Purgeable."
                 + (other > 0 ? " The \(other) other snapshot\(other == 1 ? " (com.apple.os.update…) belongs" : "s (com.apple.os.update…) belong") to macOS updates and the sealed system volume." : ""))
                .font(.system(size: 11)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    static let dateFormat: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()

    /// Distinct in every theme: colour roles from the palette, then opacity so single-hue themes still separate.
    func color(_ k: StorageSegment.Kind) -> Color {
        switch k {
        case .data: p.accent
        case .purgeable: p.accent.opacity(0.45)
        case .system: p.accent2
        case .preboot: p.eCore.opacity(0.85)
        case .recovery: p.accent2.opacity(0.55)
        case .vm: p.warn.opacity(0.8)
        case .update: p.eCore.opacity(0.45)
        case .otherVolumes: p.pCore.opacity(0.6)
        case .overhead: p.dim.opacity(0.6)
        case .free: p.meterOff
        }
    }
}

/// A horizontal bar split into proportional parts. Tiny parts get a minimum width so they stay visible.
struct StackedBar: View {
    @Environment(\.palette) var p
    var segments: [StorageSegment]
    var total: UInt64
    var color: (StorageSegment.Kind) -> Color

    var body: some View {
        GeometryReader { g in
            let gap: CGFloat = 2
            let avail = g.size.width - gap * CGFloat(max(segments.count - 1, 0))
            HStack(spacing: gap) {
                ForEach(segments) { s in
                    Rectangle().fill(color(s.kind))
                        .frame(width: max(3, avail * CGFloat(Double(s.bytes) / Double(max(total, 1)))))
                        .help("\(s.title): \(Fmt.storage(s.bytes))")
                }
            }
            .frame(width: g.size.width, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}
