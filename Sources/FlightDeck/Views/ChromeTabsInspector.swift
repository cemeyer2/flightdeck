// Chrome tabs in the process inspector: the header name for a renderer that hosts tabs, and the "Chrome tabs in this
// process" section, the one place a tab's full address is shown (selectable, never copied by Copy Summary). Live only:
// a replayed recording never shows the tabs open now. The window title keeps the plain process name, because window
// titles are visible to other apps.
import SwiftUI
import FlightDeckCore

extension InspectorView {
    /// This process's tabs, from the live attribution (nil while replaying).
    var chromeTabs: ChromeTabAttribution? { e.mode == .live ? e.chromeTabs[model.identity] : nil }
}

/// The header's name in three parts: only the title truncates, so a page can't hide the site or the "(Chrome tab)" mark.
struct ChromeTabHeaderName: View {
    @Environment(\.palette) var p
    var label: ChromeTabLabel
    var body: some View {
        HStack(spacing: 5) {
            Text(label.host).fixedSize()
            if let t = label.title { Text("— \(t)").lineLimit(1).truncationMode(.tail).layoutPriority(-1) }
            if !label.suffix.isEmpty { Text(label.suffix).foregroundStyle(p.dim).fixedSize() }
        }
        .font(.system(size: 17, weight: .semibold))
        .help(label.plain)
    }
}

struct ChromeTabsInspectorSection: View {
    @Environment(\.palette) var p
    var attribution: ChromeTabAttribution

    var body: some View {
        let tabs = attribution.entries.filter { $0.kind == .tab }
        let frames = attribution.entries.filter { $0.kind != .tab }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Chrome tabs in this process").font(.headline)
                Spacer()
                if tabs.count > 1 {
                    Text("CPU and memory are shared by all \(tabs.count) tabs").font(.caption).foregroundStyle(p.dim)
                }
            }
            ForEach(Array(tabs.enumerated()), id: \.offset) { _, t in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(t.host).font(.system(size: 12, weight: .semibold)).fixedSize()
                        if !t.title.isEmpty { Text(t.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail) }
                        if t.active { Text("active").font(.caption2).foregroundStyle(p.dim) }
                        if t.audible { Image(systemName: "speaker.wave.2").font(.caption2).foregroundStyle(p.dim) }
                    }
                    Text(t.url).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            if !frames.isEmpty {
                Text("Frames from other sites").font(.subheadline).foregroundStyle(p.dim).padding(.top, 2)
                ForEach(Array(frames.enumerated()), id: \.offset) { _, f in
                    if case .frame(let inTab) = f.kind {
                        Text("\(f.host) — frame in \(inTab) tab").font(.system(size: 12))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.panel))
    }
}
