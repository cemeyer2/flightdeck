import Foundation
// The Weekly Report, part 4: the words. Turns a WeeklyReport (and the week before, for the deltas) into a headline and
// short sections of plain-English lines, each carrying the numbers behind it and the page that has more. The page,
// the PDF, "Copy as text" (Markdown), the notification and the MCP tool all use this, so they always agree.
// Sections without data are left out rather than shown empty.

public struct WeeklyDigest: Sendable {
    public enum Tone: String, Sendable { case normal, good, bad }
    public struct Line: Sendable, Hashable {
        public var text: String
        public var tone: Tone
        public init(_ text: String, _ tone: Tone = .normal) { self.text = text; self.tone = tone }
    }
    public struct Section: Sendable, Identifiable {
        public var id: String
        public var title: String
        /// Page with the details (a Destination raw value, optionally ":tab"), or nil.
        public var destination: String?
        public var lines: [Line]
    }

    public var title: String
    public var headline: String
    public var rough: Bool
    public var subhead: String
    public var sections: [Section]

    static func hours(_ h: Double) -> String {
        h <= 0 ? "none" : h < 1 ? "\(max(Int((h * 60).rounded()), 1)) min" : String(format: "%.1f h", h)
    }
    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String { "\(n) \(n == 1 ? one : many ?? one + "s")" }
    static func when(_ d: Date) -> String { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEjmm"); return f.string(from: d) }
    static func day(_ d: Date) -> String { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEMMMd"); return f.string(from: d) }
    static func month(_ d: Date) -> String { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMMyyyy"); return f.string(from: d) }

    public static func make(_ r: WeeklyReport, previous: WeeklyReport?) -> WeeklyDigest {
        let (headline, rough) = headline(r)
        var sub = "\(day(r.week.start)) – \(day(r.week.end.addingTimeInterval(-3600)))"
        if r.daysRecorded > 0 {
            sub += " · from \(plural(r.daysRecorded, "day")) of FlightDeck's records" + (r.observedHours.map { " (\(Int($0.rounded())) h sampled)" } ?? "")
        }
        if !r.isFinal { sub += " · week in progress, updated \(when(r.builtAt))" }
        let sections = [slowdowns(r), restarts(r), battery(r), storage(r, previous), network(r), compared(r, previous)].compactMap { $0 }
        return WeeklyDigest(title: "Weekly Report: \(r.week.title)", headline: headline, rough: rough, subhead: sub, sections: sections)
    }

    static func headline(_ r: WeeklyReport) -> (String, Bool) {
        var bad: [String] = []
        if r.panics > 0 { bad.append(plural(r.panics, "kernel panic")) }
        if r.unexpected > 0 { bad.append(plural(r.unexpected, "unexpected restart")) }
        if !bad.isEmpty { return ("A rough week: " + bad.joined(separator: " and "), true) }
        var busy: [(Double, String)] = []
        if r.heatHours >= 1 { busy.append((r.heatHours * 3, "\(hours(r.heatHours)) of heat slowdowns")) }
        if r.memoryHours >= 3 { busy.append((r.memoryHours, "\(hours(r.memoryHours)) of memory pressure")) }
        if r.cpuHours >= 6 { busy.append((r.cpuHours / 2, "\(hours(r.cpuHours)) of high CPU")) }
        let frozen = r.freezes.count
        if frozen >= 3 { busy.append((Double(frozen), "\(plural(frozen, "app freeze"))")) }
        if let c = r.crashes, c >= 5 { busy.append((Double(c), plural(c, "app crash", "app crashes"))) }
        if let top = busy.max(by: { $0.0 < $1.0 }) { return ("A busy week: " + top.1, false) }
        if r.daysRecorded == 0 && r.incidentCount == 0 && r.restarts.isEmpty { return ("Not much recorded this week", false) }
        return ("A calm week", false)
    }

    static func slowdowns(_ r: WeeklyReport) -> Section? {
        var l: [Line] = []
        var spans: [String] = []
        if r.cpuHours > 0 { spans.append("high CPU for \(hours(r.cpuHours))") }
        if r.memoryHours > 0 { spans.append("memory pressure for \(hours(r.memoryHours))") }
        if r.heatHours > 0 { spans.append("heat slowdowns for \(hours(r.heatHours))") }
        if !spans.isEmpty { l.append(Line("Flight Log: " + spans.joined(separator: ", ") + ".", r.heatHours >= 1 || r.memoryHours >= 3 ? .bad : .normal)) }
        // Other kinds (a disk filling up, a fast battery drain) are counted, but have their own sections or pages.
        for i in r.incidents.filter({ $0.kind != .other }).prefix(4) {
            l.append(Line("\(i.label): \(plural(i.count, "time")), \(hours(i.seconds / 3600)) in all.", i.severity >= 3 ? .bad : .normal))
        }
        if !r.topApps.isEmpty {
            l.append(Line("Most CPU time: " + r.topApps.map { "\($0.name) \(hours($0.cpuHours))" }.joined(separator: ", ") + "."))
        }
        if let t = r.hottest {
            let states = ["nominal", "fair", "serious", "critical"]
            let worst = r.worstThermalState.map { " Thermal pressure peaked at \(states[min(max($0, 0), 3)])." } ?? ""
            l.append(Line("Hottest sensor: \(Fmt.temp(t)).\(worst)", (r.worstThermalState ?? 0) >= 2 ? .bad : .normal))
        }
        if let c = r.cpuAverage { l.append(Line(String(format: "Average CPU while FlightDeck was sampling: %.0f%%.", c))) }
        if r.incompleteDays > 0, !l.isEmpty || r.daysRecorded > 0 {
            l.append(Line("The Flight Log keeps 7 days; \(plural(r.incompleteDays, "day")) of this week may be missing from the incident counts."))
        }
        return l.isEmpty ? nil : Section(id: "slowdowns", title: "What slowed the Mac down", destination: "Flight Log", lines: l)
    }

    static func restarts(_ r: WeeklyReport) -> Section? {
        var l: [Line] = []
        for e in r.restarts { l.append(Line("\(e.title), \(when(e.time))" + (e.detail.map { ": \($0)" } ?? "."), .bad)) }
        if r.restarts.isEmpty, let b = r.boots, b > 0 { l.append(Line("\(plural(b, "boot")), all after a normal shutdown or restart.", .good)) }
        if !r.freezes.isEmpty {
            var by: [String: Int] = [:]
            for f in r.freezes { by[f.title.replacingOccurrences(of: " froze", with: ""), default: 0] += 1 }
            let names = by.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { $0.value > 1 ? "\($0.key) (\($0.value))" : $0.key }
            l.append(Line("\(plural(r.freezes.count, "app freeze")): " + names.joined(separator: ", ") + ".", .bad))
        }
        if let c = r.crashes, c > 0 {
            let names = r.crashesByProcess.sorted { $0.value > $1.value }.prefix(4).map { $0.value > 1 ? "\($0.key) (\($0.value))" : $0.key }
            l.append(Line("\(plural(c, "app crash", "app crashes"))" + (names.isEmpty ? "." : ": " + names.joined(separator: ", ") + "."), c >= 5 ? .bad : .normal))
        }
        return l.isEmpty ? nil : Section(id: "restarts", title: "Restarts, panics and freezes", destination: "Restarts & Crashes", lines: l)
    }

    static func battery(_ r: WeeklyReport) -> Section? {
        guard let b = r.battery else { return nil }
        var l: [Line] = []
        if let used = b.cyclesUsed, let s = b.cyclesStart, let e = b.cyclesEnd {
            l.append(Line("Used \(plural(used, "charge cycle")) (\(s) → \(e)).", used >= 7 ? .bad : .normal))
        }
        if let s = b.healthStart, let e = b.healthEnd {
            let ch = e - s
            l.append(Line(abs(ch) < 0.5 ? String(format: "Health held at %.0f%% of design.", e)
                          : String(format: "Health %.0f%% → %.0f%% (%@%.0f point%@).", s, e, ch > 0 ? "+" : "−", abs(ch), abs(ch) >= 1.5 ? "s" : ""),
                          ch <= -1.5 ? .bad : .normal))
        }
        if let f = b.forecast80 {
            var s = "Forecast to reach 80% health around \(month(f))"
            if let before = b.forecast80Before {
                let days = f.timeIntervalSince(before) / 86_400
                if abs(days) >= 30 { s += " (\(Int(abs(days) / 30)) month\(abs(days) >= 60 ? "s" : "") \(days < 0 ? "sooner" : "later") than a week earlier)" }
                else { s += " (about the same as a week earlier)" }
            }
            l.append(Line(s + "."))
        } else if let n = b.forecastNote { l.append(Line("No 80% forecast: \(n)")) }
        return l.isEmpty ? nil : Section(id: "battery", title: "Battery", destination: "Performance:Energy", lines: l)
    }

    static func storage(_ r: WeeklyReport, _ prev: WeeklyReport?) -> Section? {
        guard let s = r.storage else { return nil }
        var l = [Line("Startup disk: \(Fmt.storage(s.used)) used of \(Fmt.storage(s.capacity)), \(Fmt.storage(s.free)) free.", s.free < s.capacity / 20 ? .bad : .normal)]
        if let p = prev?.storage, p.capacity == s.capacity {
            let grew = Double(s.used) - Double(p.used)
            if abs(grew) >= 1e9 { l.append(Line("\(grew > 0 ? "Grew" : "Shrank") by \(Fmt.storage(abs(grew))) since \(day(p.readAt)).", grew > 50e9 ? .bad : .normal)) }
            else { l.append(Line("About the same as on \(day(p.readAt)).")) }
        }
        if let d = s.fullInDays { l.append(Line("At the current rate it will be full in about \(plural(max(Int(d.rounded()), 1), "day")).", d < 14 ? .bad : .normal)) }
        return Section(id: "storage", title: "Storage", destination: "Disk Space", lines: l)
    }

    static func network(_ r: WeeklyReport) -> Section? {
        var l: [Line] = []
        if let u = r.dataUsed { l.append(Line("Internet data: \(Fmt.bytes(u)) counted on \(plural(r.dataDays, "day")).")) }
        let worth = r.newDestinations.filter { !DestinationFindings.browsers.contains($0.app) }
        if !worth.isEmpty {
            let shown = worth.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }.prefix(4).map { d in
                "\(d.app) → \(d.destination) (first \(day(d.first))" + (d.bytes.map { ", \(Fmt.bytes($0))" } ?? "") + ")"
            }
            let more = worth.count > 4 ? ", and \(worth.count - 4) more" : ""
            l.append(Line("\(plural(worth.count, "new destination")) worth a look: " + shown.joined(separator: "; ") + more + ".", .bad))
        }
        let browsers = r.newDestinations.count - worth.count
        if browsers > 0 { l.append(Line("\(plural(browsers, "new destination")) from web browsers, not listed.")) }
        return l.isEmpty ? nil : Section(id: "network", title: "Network", destination: "Destinations", lines: l)
    }

    static func compared(_ r: WeeklyReport, _ p: WeeklyReport?) -> Section? {
        guard let p, p.daysRecorded > 0 || p.incidentCount > 0 else { return nil }
        var l: [Line] = []
        func row(_ name: String, _ now: Double, _ then: Double, _ f: (Double) -> String, higherIsWorse: Bool = true) {
            guard now > 0 || then > 0 else { return }
            let d = now - then
            let tone: Tone = abs(d) < max(then * 0.1, 0.05) ? .normal : (d > 0) == higherIsWorse ? .bad : .good
            let change = abs(d) < 1e-9 ? "same as" : "\(d > 0 ? "up" : "down") from"
            l.append(Line("\(name): \(f(now)), \(change) \(f(then)) the week before.", tone))
        }
        let n: (Double) -> String = { "\(Int($0))" }
        row("Unexpected restarts and panics", Double(r.restarts.count), Double(p.restarts.count), n)
        row("Flight Log incidents", Double(r.incidentCount), Double(p.incidentCount), n)
        row("High CPU", r.cpuHours, p.cpuHours, hours)
        row("Memory pressure", r.memoryHours, p.memoryHours, hours)
        row("Heat slowdowns", r.heatHours, p.heatHours, hours)
        row("App freezes", Double(r.freezes.count), Double(p.freezes.count), n)
        if let a = r.crashes, let b = p.crashes { row("App crashes", Double(a), Double(b), n) }
        if let a = r.cpuAverage, let b = p.cpuAverage { row("Average CPU", a, b, { String(format: "%.0f%%", $0) }) }
        if let a = r.dataUsed, let b = p.dataUsed { row("Internet data", Double(a), Double(b), { Fmt.bytes($0) }, higherIsWorse: false) }
        if let a = r.battery?.cyclesUsed, let b = p.battery?.cyclesUsed { row("Battery cycles", Double(a), Double(b), n) }
        // Data use is neither good nor bad: keep its tone neutral.
        l = l.map { $0.text.hasPrefix("Internet data") ? Line($0.text) : $0 }
        return l.isEmpty ? nil : Section(id: "compared", title: "Compared with the week before", destination: "Trends", lines: l)
    }

    /// The digest as Markdown ("Copy as text", the MCP tool's text).
    public var markdown: String {
        var s = "# \(title)\n\n**\(headline)**\n\n_\(subhead)_\n"
        for sec in sections {
            s += "\n## \(sec.title)\n\n"
            for line in sec.lines { s += "- \(line.text)\n" }
            if let d = sec.destination { s += "\nMore in FlightDeck › \(d.replacingOccurrences(of: ":", with: " › ")).\n" }
        }
        return s
    }

    /// One line for the notification body.
    public var notificationBody: String {
        let first = sections.first?.lines.first?.text
        return [subhead.components(separatedBy: " · ").first, first].compactMap { $0 }.joined(separator: ". ")
    }
}
