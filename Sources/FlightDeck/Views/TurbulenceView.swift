// Turbulence, FlightDeck 1.5's easter egg (see EasterEgg.swift): fly a paper plane through your Mac's recent history.
// The game logic is TurbulenceGame (FlightDeckCore); this draws it with a Canvas on every display frame, but only
// while the egg is open, and handles the keys: space or ↑ (or the mouse) climbs, Return or space takes off, Esc lands.
import SwiftUI
import AppKit
import FlightDeckCore

/// Mutable flight state, advanced from the Canvas's frame times. Only `phase` and `course` are published, so SwiftUI
/// re-renders the overlays on takeoff and crash, not on every frame.
@MainActor
final class TurbulenceModel: ObservableObject {
    @Published private(set) var course: TurbulenceCourse?
    @Published private(set) var phase: TurbulenceGame.Phase = .ready
    @Published private(set) var best = UserDefaults.standard.integer(forKey: "turbulenceBest")
    private(set) var game: TurbulenceGame?
    var climbing = false
    private var last: Date?
    /// Recent plane positions (course x, height) for the vapour trail.
    private(set) var trail: [(x: Double, y: Double)] = []

    /// History to fly: the black box's last 40 minutes (10 s frames); failing that its fine tier, then the live window.
    /// Demo mode flies only the engine's invented frames.
    func load(_ engine: Engine) {
        let live = engine.frames.compactMap { $0 }
        if Demo.isEnabled { setCourse(TurbulenceCourse.from(live)); return }
        engine.blackBoxQueue.async { [blackBox = engine.blackBox] in
            let now = Date()
            var frames = blackBox.trace(.coarse, from: now.addingTimeInterval(-2400))?.frames ?? []
            if frames.count < 30 { frames = blackBox.trace(.fine, from: now.addingTimeInterval(-1800))?.frames ?? [] }
            if frames.count < 30 { frames = live }
            let course = TurbulenceCourse.from(frames)
            DispatchQueue.main.async { self.setCourse(course) }
        }
    }

    init() {}

    /// For renders: a course flown by an autopilot (aiming for the middle of the gap ahead) for `seconds`, then
    /// optionally crashed, since ImageRenderer runs no frames.
    init(preview course: TurbulenceCourse, flyFor seconds: Double = 0, crash: Bool = false) {
        setCourse(course)
        guard seconds > 0, var g = game else { return }
        g.start()
        var t = 0.0
        while t < seconds, g.phase == .flying {
            let ahead = course.at(g.planeX + 3), target = (ahead.ground + 1 - ahead.ceiling) / 2
            g.step(1.0 / 60, climbing: g.y < target && g.vy < 0.5); t += 1.0 / 60
            if Int(t * 60) % 3 == 0 { trail.append((g.planeX, g.y)); if trail.count > 40 { trail.removeFirst() } }
        }
        while crash, g.phase == .flying { g.step(1.0 / 60, climbing: false) }
        game = g; phase = g.phase
    }

    private func setCourse(_ c: TurbulenceCourse) { course = c; game = TurbulenceGame(course: c); phase = .ready }

    func takeOff() {
        guard var g = game, g.phase != .flying else { return }
        g.start(); game = g; trail = []; last = nil; phase = .flying
    }

    /// Steps the game to the frame time `now`. Called while drawing, so the crash is published on the next turn.
    func advance(to now: Date) {
        guard var g = game, g.phase == .flying else { last = nil; return }
        let dt = last.map { now.timeIntervalSince($0) } ?? 0
        last = now
        g.step(dt, climbing: climbing)
        game = g
        trail.append((g.planeX, g.y)); if trail.count > 40 { trail.removeFirst() }
        if g.phase == .crashed {
            let score = g.score
            DispatchQueue.main.async {
                self.phase = .crashed
                if score > self.best { self.best = score; UserDefaults.standard.set(score, forKey: "turbulenceBest") }
            }
        }
    }
}

struct TurbulenceView: View {
    @Environment(\.palette) var p
    let engine: Engine
    let close: () -> Void
    @StateObject private var model: TurbulenceModel
    @State private var monitor: Any?
    private let preview: Bool

    init(engine: Engine, close: @escaping () -> Void, preview model: TurbulenceModel? = nil) {
        self.engine = engine; self.close = close; preview = model != nil
        _model = StateObject(wrappedValue: model ?? TurbulenceModel())
    }

    var body: some View {
        ZStack {
            p.background.opacity(0.97).ignoresSafeArea()
            if let course = model.course {
                TimelineView(.animation(paused: model.phase != .flying)) { tl in
                    Canvas { ctx, size in
                        model.advance(to: tl.date)
                        draw(&ctx, size, course)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if model.phase != .flying { model.takeOff() }; model.climbing = true }
                    .onEnded { _ in model.climbing = false })
            }
            if model.phase == .ready, let c = model.course {
                BoardingPass(from: c.columns.first?.time, invented: c.secondsPerColumn == 0)
            }
            if model.phase == .crashed, let g = model.game { crashCard(g) }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2) }
                .buttonStyle(.plain).foregroundStyle(p.dim).padding(14).help("Land (Esc)")
        }
        .onAppear { if !preview { model.load(engine); installKeys() } }
        .onDisappear { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }
    }

    /// While the egg is open it owns space, ↑, Return and Esc; every other key passes through.
    private func installKeys() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [model] e in
            let climbKey = e.keyCode == 49 || e.keyCode == 126   // space, ↑
            switch (e.type, e.keyCode) {
            case (.keyDown, 53): close(); return nil                                   // Esc
            case (.keyDown, 36): if model.phase != .flying { model.takeOff() }; return nil   // Return
            case (.keyDown, _) where climbKey:
                if model.phase != .flying, !e.isARepeat { model.takeOff() }
                model.climbing = true; return nil
            case (.keyUp, _) where climbKey: model.climbing = false; return nil
            default: return e
            }
        }
    }

    private func crashCard(_ g: TurbulenceGame) -> some View {
        let flown = g.course.secondsPerColumn > 0
            ? "You flew through \(Duration.seconds(g.historyFlown).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))) of your Mac's history."
            : "You flew \(g.score) columns of invented sky."
        return VStack(spacing: 8) {
            Text("TURBULENCE!").font(.system(size: 26, weight: .heavy, design: .monospaced)).foregroundStyle(p.crit)
            Text(flown).font(.callout)
            Text(g.score >= model.best && g.score > 0 ? "New best: \(g.score)" : "Score \(g.score) · best \(model.best)")
                .font(.meterLabel).foregroundStyle(p.accent)
            Text("space to fly again · esc to land").font(.caption2).foregroundStyle(p.dim).padding(.top, 4)
        }
        .foregroundStyle(p.text)
        .padding(.horizontal, 28).padding(.vertical, 20)
        .background(RoundedRectangle(cornerRadius: 14).fill(p.panel.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.panelBorder))
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ course: TurbulenceCourse) {
        guard let g = model.game else { return }
        let top: CGFloat = 46, bottom: CGFloat = 24
        let h = size.height - top - bottom, colW = size.width / TurbulenceGame.visibleColumns
        func sy(_ frac: Double) -> CGFloat { top + h * (1 - frac) }               // play-area fraction → screen y
        func cx(_ x: CGFloat) -> Double { g.distance + Double(x / colW) }       // screen x → course x
        func sx(_ x: Double) -> CGFloat { CGFloat(x - g.distance) * colW }      // course x → screen x

        // Time ticks on whole minutes (at least 6 columns apart), labelled with when that slice of history happened.
        let perMinute = course.secondsPerColumn > 0 ? max(1, (60 / course.secondsPerColumn).rounded()) : 10
        let every = perMinute * max(1, (6 / perMinute).rounded(.up))
        let firstTick = (g.distance / every).rounded(.up) * every
        for k in stride(from: firstTick, through: g.distance + TurbulenceGame.visibleColumns, by: every) {
            let x = sx(k)
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: top)); $0.addLine(to: CGPoint(x: x, y: top + h)) },
                       with: .color(p.grid.opacity(0.5)), lineWidth: 0.5)
            if let t = course.column(at: k)?.time {
                ctx.draw(Text(t.formatted(date: .omitted, time: .shortened)).font(.system(size: 9, design: .monospaced))
                    .foregroundColor(p.dim), at: CGPoint(x: x, y: top + h + 12))
            }
        }

        // Clouds (memory pressure) from the top, mountains (CPU) from the bottom.
        var ground = Path(), ceiling = Path()
        ground.move(to: CGPoint(x: 0, y: top + h)); ceiling.move(to: CGPoint(x: 0, y: top))
        for x in stride(from: CGFloat(0), through: size.width + 4, by: 4) {
            let a = course.at(cx(x))
            ground.addLine(to: CGPoint(x: x, y: sy(a.ground))); ceiling.addLine(to: CGPoint(x: x, y: sy(1 - a.ceiling)))
        }
        ground.addLine(to: CGPoint(x: size.width + 4, y: top + h)); ceiling.addLine(to: CGPoint(x: size.width + 4, y: top))
        ctx.fill(ground, with: .linearGradient(Gradient(colors: [p.accent.opacity(0.55), p.accent.opacity(0.12)]),
                                               startPoint: CGPoint(x: 0, y: top + h * 0.3), endPoint: CGPoint(x: 0, y: top + h)))
        ctx.fill(ceiling, with: .linearGradient(Gradient(colors: [p.dim.opacity(0.10), p.dim.opacity(0.32)]),
                                                startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: top + h * 0.4)))

        // The busiest app's name on each big peak.
        for k in Int(g.distance.rounded(.down))...Int(g.distance + TurbulenceGame.visibleColumns) {
            guard let label = course.column(at: Double(k))?.label else { continue }
            let x = sx(Double(k)), y = sy(course.at(Double(k)).ground)
            ctx.draw(Text("▲ \(label)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(p.text),
                     at: CGPoint(x: x, y: y - 10))
        }

        // Vapour trail, then the plane, nose tilted with its climb rate.
        for (i, t) in model.trail.enumerated() {
            let o = Double(i) / Double(max(1, model.trail.count))
            ctx.fill(Path(ellipseIn: CGRect(x: sx(t.x) - 1.5, y: sy(t.y) - 1.5, width: 3, height: 3)), with: .color(p.dim.opacity(o * 0.6)))
        }
        let plane = CGPoint(x: sx(g.planeX), y: sy(g.y))
        var pc = ctx
        pc.translateBy(x: plane.x, y: plane.y)
        pc.rotate(by: .radians(-atan(g.vy * 0.8)))
        let s = max(9, h * 0.028)
        let body = Path { $0.move(to: CGPoint(x: s * 1.6, y: 0)); $0.addLine(to: CGPoint(x: -s, y: -s * 0.8))
            $0.addLine(to: CGPoint(x: -s * 0.4, y: 0)); $0.addLine(to: CGPoint(x: -s, y: s * 0.8)); $0.closeSubpath() }
        pc.fill(body, with: .color(g.phase == .crashed ? p.crit : p.text))
        pc.stroke(Path { $0.move(to: CGPoint(x: s * 1.6, y: 0)); $0.addLine(to: CGPoint(x: -s * 0.4, y: 0)) },
                  with: .color(p.background.opacity(0.6)), lineWidth: 1)

        // Heads-up display.
        ctx.draw(Text("FD ✈ \(EasterEggs.title.uppercased())").font(.system(size: 12, weight: .heavy, design: .monospaced))
            .foregroundColor(p.accent), at: CGPoint(x: 16, y: 22), anchor: .leading)
        var hud = "score \(g.score)   best \(max(model.best, g.phase == .crashed ? g.score : 0))"
        if let t = course.column(at: g.planeX)?.time { hud = "over \(t.formatted(date: .omitted, time: .shortened))   " + hud }
        ctx.draw(Text(hud).font(.system(size: 11, design: .monospaced)).foregroundColor(p.dim),
                 at: CGPoint(x: size.width - 56, y: 22), anchor: .trailing)
    }
}

extension TurbulenceModel {
    /// An invented 20-minute course (10 s columns) with two named peaks, for renders.
    static func previewCourse() -> TurbulenceCourse {
        let start = Date().addingTimeInterval(-1200)
        let cpu = (0..<120).map { i -> Double in
            let x = Double(i)
            return 18 + 10 * sin(x / 6) + (abs(x - 45) < 6 ? 70 - abs(x - 45) * 6 : 0) + (abs(x - 90) < 5 ? 55 - abs(x - 90) * 7 : 0)
        }
        let ground = TurbulenceCourse.rampLimited(cpu.map { 0.06 + min(max($0, 0), 100) / 100 * 0.56 })
        let cols = ground.indices.map { i in
            TurbulenceCourse.Column(ground: ground[i], ceiling: min(0.08 + 0.06 * sin(Double(i) / 9), 1 - TurbulenceCourse.minGap - ground[i]),
                                    time: start.addingTimeInterval(Double(i) * 10),
                                    label: i == 45 ? "Compiler" : i == 90 ? "Photo Editor" : nil)
        }
        return TurbulenceCourse(columns: cols, secondsPerColumn: 10)
    }
}
