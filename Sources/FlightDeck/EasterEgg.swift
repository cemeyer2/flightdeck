// Easter eggs: typing the Konami code (↑ ↑ ↓ ↓ ← → ← → B A) in any FlightDeck window opens this version's egg over the
// main window. Each version gets its own; 1.5's is Turbulence (Views/TurbulenceView.swift). The key watcher only
// observes key presses (it never swallows them), so typing the code into a search field still types.
import SwiftUI
import AppKit
import FlightDeckCore

@MainActor
final class EasterEggs: ObservableObject {
    static let shared = EasterEggs()
    @Published var visible = false
    private var konami = KonamiCode()
    private var monitor: Any?

    /// This version's egg, shown in its title card.
    static let title = "Turbulence"

    /// Installs the key watcher once (idempotent).
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.observe(e)
            return e
        }
    }

    private func observe(_ e: NSEvent) {
        guard !visible, e.modifierFlags.intersection([.command, .control, .option]).isEmpty, !e.isARepeat else { return }
        let key: KonamiCode.Key
        switch e.keyCode {
        case 126: key = .up
        case 125: key = .down
        case 123: key = .left
        case 124: key = .right
        default:
            // Letters by character, not key position, so B and A work on any keyboard layout.
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "b": key = .b
            case "a": key = .a
            default: key = .other
            }
        }
        if konami.feed(key) { visible = true }
    }
}

/// Shows the egg over the main window's content.
struct EasterEggOverlay: ViewModifier {
    @ObservedObject var eggs = EasterEggs.shared
    @EnvironmentObject var engine: Engine
    @Environment(\.palette) var p
    func body(content: Content) -> some View {
        content
            .overlay {
                if eggs.visible {
                    TurbulenceView(engine: engine, close: { eggs.visible = false })
                        .environment(\.palette, p)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeOut(duration: 0.25), value: eggs.visible)
            .onAppear { EasterEggs.shared.install() }
    }
}

/// The title card before takeoff: a boarding pass for flight FD 1.5, from the start of the history being flown to now.
struct BoardingPass: View {
    @Environment(\.palette) var p
    let from: Date?
    let invented: Bool
    var version: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { String($0.split(separator: ".").prefix(2).joined(separator: ".")) } ?? "1.5" }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("BOARDING PASS").font(.meterLabel).foregroundStyle(p.dim)
                    Spacer()
                    Text("FLIGHTDECK AIR").font(.meterLabel).foregroundStyle(p.accent)
                }
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    field("FLIGHT", "FD \(version)")
                    field("FROM", from.map { $0.formatted(date: .omitted, time: .shortened) } ?? "NOWHERE")
                    Image(systemName: "airplane").font(.title2).foregroundStyle(p.accent)
                    field("TO", "NOW")
                }
                HStack(spacing: 18) {
                    field("GATE", "CPU", small: true)
                    field("SEAT", "1A", small: true)
                    field("CLASS", "TURBULENT", small: true)
                }
                Text(invented
                     ? "No flight history yet, so today's route is invented. Come back after FlightDeck has run a while."
                     : "The mountains are your Mac's CPU load and the clouds its memory pressure, from the black box. The tallest peaks are named after the app that caused them.")
                    .font(.caption).foregroundStyle(p.dim).lineLimit(3)
            }
            .padding(18)
            // The tear-off stub, behind a perforated line.
            Rectangle().fill(.clear).frame(width: 1)
                .overlay(Line().stroke(p.dim.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 4])))
            VStack(spacing: 8) {
                Text(EasterEggs.title.uppercased()).font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundStyle(p.accent)
                Text("Hold space or the mouse to climb").font(.caption).multilineTextAlignment(.center)
                Text("space to take off · esc to land").font(.caption2).foregroundStyle(p.dim)
            }
            .frame(width: 150).padding(14)
        }
        .foregroundStyle(p.text)
        // Its own height, not the whole overlay's: the perforation line would otherwise stretch it to fill the window.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 14).fill(p.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.panelBorder))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }

    func field(_ label: String, _ value: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(p.dim)
            Text(value).font(.system(size: small ? 13 : 22, weight: .bold, design: .monospaced))
        }
    }

    struct Line: Shape {
        func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: r.midX, y: r.minY)); $0.addLine(to: CGPoint(x: r.midX, y: r.maxY)) } }
    }
}
