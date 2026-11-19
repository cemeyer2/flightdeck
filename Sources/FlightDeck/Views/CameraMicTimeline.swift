// The Camera & Mic timeline: one row per day (today first), the hours of the day across, and two labelled lanes per
// row, camera above microphone, so the kind is told by position as well as colour (the single-hue themes give the two
// only different shades). Midnight to 6 a.m. is shaded; a session at those hours, while the screen was locked or idle,
// or an app's first use gets a warning outline (and a badge in the list below). Hovering a bar shows the session.
import SwiftUI
import FlightDeckCore

struct CameraMicTimeline: View {
    let sessions: [SensorSession]
    let range: CameraMicRange
    let now: Date
    @Environment(\.palette) var p
    private let cal = Calendar.current

    /// Lane height: taller when only today is shown.
    var lane: CGFloat { range == .today ? 16 : range == .week ? 9 : 5 }
    static let labelWidth: CGFloat = 92

    /// A piece of a session within one day (sessions over midnight are split), as fractions of the day.
    struct Piece: Identifiable { let id: String; let row: Int; let kind: SensorKind; let x0: Double; let x1: Double; let session: SensorSession }

    func pieces(days: [Date]) -> [Piece] {
        var out: [Piece] = []
        for (row, day) in days.enumerated() {
            let next = cal.date(byAdding: .day, value: 1, to: day)!
            for s in sessions {
                let a = max(s.start, day), b = min(s.end ?? now, next)
                guard b > a || (s.start >= day && s.start < next) else { continue }
                out.append(Piece(id: "\(s.id)-\(row)", row: row, kind: s.kind, x0: a.timeIntervalSince(day) / 86_400,
                                 x1: max(b, a).timeIntervalSince(day) / 86_400, session: s))
            }
        }
        return out
    }

    func flagged(_ s: SensorSession) -> Bool { s.firstUse || s.whileLocked || s.whileIdle || s.atUnusualHour(cal) }

    var body: some View {
        let today = cal.startOfDay(for: now)
        let days = (0..<range.days).map { cal.date(byAdding: .day, value: -$0, to: today)! }
        let rowH = lane * 2 + 5
        let ps = pieces(days: days)
        Panel(title: "Timeline", trailing: "\(sessions.count) session\(sessions.count == 1 ? "" : "s")") {
            legend
            hourAxis
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                        Text(dayLabel(d)).font(.system(size: range == .month ? 9 : 11, design: .monospaced)).foregroundStyle(p.dim)
                            .frame(width: Self.labelWidth, height: rowH, alignment: .leading)
                    }
                }
                GeometryReader { g in
                    let w = g.size.width
                    ZStack(alignment: .topLeading) {
                        // Midnight-6 a.m. band, and hour gridlines every 3 hours.
                        Rectangle().fill(p.warn.opacity(0.08)).frame(width: w * 0.25)
                        ForEach(1..<8) { h in Rectangle().fill(p.grid).frame(width: 1).offset(x: w * Double(h) / 8) }
                        ForEach(Array(days.indices), id: \.self) { r in
                            Rectangle().fill(p.grid.opacity(0.5)).frame(height: 1).offset(y: CGFloat(r + 1) * rowH - 1)
                        }
                        ForEach(ps) { piece in bar(piece, width: w, rowH: rowH) }
                        // "Now" marker on today's row.
                        Rectangle().fill(p.text.opacity(0.6)).frame(width: 1, height: rowH)
                            .offset(x: w * now.timeIntervalSince(today) / 86_400)
                    }
                }
                .frame(height: rowH * CGFloat(days.count))
            }
            if sessions.isEmpty {
                Text("No camera or microphone use recorded in this range.").font(.caption).foregroundStyle(p.dim)
            }
        }
    }

    func bar(_ piece: Piece, width w: CGFloat, rowH: CGFloat) -> some View {
        let s = piece.session
        let x = w * piece.x0, bw = max(3, w * (piece.x1 - piece.x0))
        let y = CGFloat(piece.row) * rowH + 2 + (piece.kind == .camera ? 0 : lane + 1)
        let shape = RoundedRectangle(cornerRadius: min(2, lane / 2))
        return shape.fill(piece.kind == .camera ? p.accent : p.accent2)
            .overlay(shape.strokeBorder(flagged(s) ? p.warn : .clear, lineWidth: 1.5))
            .frame(width: bw, height: lane)
            .offset(x: x, y: y)
            .help(tooltip(s))
    }

    func tooltip(_ s: SensorSession) -> String {
        let end = s.end.map { $0.formatted(date: .omitted, time: .shortened) } ?? "now"
        var t = "\(s.kind.title): \(s.appLabel)\n\(s.start.formatted(date: .abbreviated, time: .shortened)) – \(end) (\(CameraMicFindings.span(s.duration(now: now))))"
        if !s.devices.isEmpty { t += "\n" + s.devices.joined(separator: ", ") }
        t += "\n" + s.how
        return t
    }

    func dayLabel(_ d: Date) -> String {
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    var hourAxis: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: Self.labelWidth)
            GeometryReader { g in
                ForEach(0..<8) { i in
                    Text(String(format: "%02d", i * 3)).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.dim)
                        .offset(x: g.size.width * Double(i) / 8)
                }
            }.frame(height: 12)
        }
    }

    var legend: some View {
        HStack(spacing: 14) {
            swatch(p.accent, "Camera (upper lane)")
            swatch(p.accent2, "Microphone (lower lane)")
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(p.warn, lineWidth: 1.5).frame(width: 14, height: 8)
                Text("First use, 00–06, locked or idle")
            }
            HStack(spacing: 4) { Rectangle().fill(p.warn.opacity(0.15)).frame(width: 14, height: 8); Text("Midnight–6 a.m.") }
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim)
    }

    func swatch(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 14, height: 8); Text(label) }
    }
}
