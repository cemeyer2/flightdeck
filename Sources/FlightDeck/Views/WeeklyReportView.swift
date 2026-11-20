import SwiftUI
import FlightDeckCore
// Weekly Report destination: one calendar week (Monday to Sunday) of how this Mac did, in plain English with the
// numbers behind each line and a link to the page with the details. A picker reaches every saved week. The wording is
// WeeklyDigest's (FlightDeckCore), shared with the PDF, "Copy as text", the notification and the MCP tool; the export
// is in WeeklyReportExport.swift.

struct WeeklyReportView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    @ObservedObject var model: WeeklyReportModel

    init(model: WeeklyReportModel? = nil) { self.model = model ?? .shared }

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("How this Mac did each week, Monday to Sunday, from what FlightDeck recorded.").foregroundStyle(p.dim)
                    if model.loading { ProgressView().controlSize(.small) }
                    Spacer()
                    if !model.reports.isEmpty {
                        Picker("Week", selection: Binding(get: { model.selected?.id ?? "" }, set: { model.selection = $0 })) {
                            ForEach(Array(model.reports.enumerated()), id: \.element.id) { i, r in
                                Text(i == 0 && !r.isFinal ? "This week so far" : "Week of \(r.week.title)").tag(r.id)
                            }
                        }.labelsHidden().frame(width: 200)
                    }
                    if let r = model.selected {
                        let d = WeeklyDigest.make(r, previous: model.previous(of: r))
                        Button("Copy as Text") { WeeklyReportExport.copy(d) }.help("Copy the report as Markdown")
                        Button("Save as PDF…") { WeeklyReportExport.savePDF(d) }
                    }
                }.font(.system(size: 12))
                if let r = model.selected {
                    WeeklyReportContent(digest: WeeklyDigest.make(r, previous: model.previous(of: r))) { e.navigationRequest = $0 }
                } else if model.loading {
                    Text("Building the report from the daily log, the Flight Log and the boot records…").foregroundStyle(p.dim)
                } else {
                    Text("No weeks recorded yet. The report fills in as FlightDeck runs.").foregroundStyle(p.dim)
                }
            }.padding(16)
        }
        .task {
            // On open, rebuild unless it was just done (the background service also builds once a day).
            if !model.fixed, model.loadedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true { await model.load(engine: e) }
        }
    }
}

/// The report itself: headline, then one panel per section. `open` (nil in the PDF) adds the links to other pages.
struct WeeklyReportContent: View {
    @Environment(\.palette) var p
    let digest: WeeklyDigest
    var open: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WeeklyHeadline(digest: digest)
            ForEach(digest.sections) { s in WeeklySectionPanel(section: s, open: open) }
        }
    }
}

struct WeeklyHeadline: View {
    @Environment(\.palette) var p
    let digest: WeeklyDigest
    var body: some View {
        Panel(title: digest.title) {
            Text(digest.headline).font(.system(size: 22, weight: .semibold)).foregroundStyle(digest.rough ? p.crit : p.text)
            Text(digest.subhead).font(.system(size: 12)).foregroundStyle(p.dim)
        }
    }
}

struct WeeklySectionPanel: View {
    @Environment(\.palette) var p
    let section: WeeklyDigest.Section
    var open: ((String) -> Void)? = nil

    func color(_ t: WeeklyDigest.Tone) -> Color { t == .bad ? p.warn : t == .good ? Color.green : p.dim.opacity(0.6) }

    var body: some View {
        Panel(title: section.title) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(color(line.tone)).frame(width: 7, height: 7)
                        Text(line.text).font(.system(size: 13)).foregroundStyle(p.text)
                    }
                }
                if let d = section.destination, let open {
                    Button { open(d) } label: {
                        Text("Open \(d.replacingOccurrences(of: ":", with: " › ")) ›").font(.system(size: 12))
                    }.buttonStyle(.link).padding(.top, 2)
                }
            }
        }
    }
}
