import SwiftUI
import FlightDeckCore
// Rules destination: list, toggle, edit and delete the user's automation rules (`e.rules`, persisted by Engine in
// user defaults and mirrored to the RuleEngine on the sampling queue), plus this session's log of rule actions.
// Evaluation and the actions themselves live in FlightDeckCore/Rules.swift and Engine.execute.

/// Edits go straight into `e.rules` through bindings; every change is saved and pushed to the rule engine by
/// Engine's `didSet`, so there is no separate Apply step.
struct RulesView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.palette) var p
    /// Rule shown in the editor sheet; non-nil presents the sheet.
    @State private var editing: Rule?
    @State private var isNew = false

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 12) {
                Panel(title: "Rules", trailing: "\(e.rules.filter(\.enabled).count) of \(e.rules.count) on") {
                    // The protection list (kernel_task, launchd, WindowServer, FlightDeck…) is RuleEngine.protected.
                    Text("Automatic responses to sustained problems: notify, lower priority, suspend, quit, or run your own command. Rules never act on FlightDeck or core macOS processes, and every action posts a notification.")
                        .font(.caption).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                    if e.rules.isEmpty {
                        Text("No rules yet.").foregroundStyle(p.dim)
                    }
                    ForEach($e.rules) { $r in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Toggle("", isOn: $r.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).font(.system(size: 13, weight: .semibold))
                                // Rules whose action suspends or quits are drawn in the warning colour as a reminder.
                                Text(r.sentence).font(.system(size: 11, design: .monospaced)).foregroundStyle(r.action.isDestructive ? p.warn : p.dim)
                            }
                            Spacer()
                            Button("Edit") { isNew = false; editing = r }
                            Button(role: .destructive) { e.rules.removeAll { $0.id == r.id } } label: { Image(systemName: "trash") }
                        }.buttonStyle(.borderless)
                    }
                    HStack {
                        Button("New Rule…") { isNew = true; editing = Rule(name: "New rule") }
                        if e.rules.isEmpty { Button("Add Examples") { e.rules += RuleEngine.examples } }
                    }
                }
                // `ruleLog` is kept in memory only, so it starts empty each launch.
                Panel(title: "Recent actions", trailing: "this session") {
                    if e.ruleLog.isEmpty { Text("No rule has fired yet.").foregroundStyle(p.dim) }
                    ForEach(e.ruleLog) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.firing.time.formatted(date: .omitted, time: .standard)).foregroundStyle(p.dim).frame(width: 80, alignment: .leading)
                            Text(entry.firing.rule.name).frame(width: 160, alignment: .leading)
                            Text("\(entry.firing.subject): \(entry.result)").lineLimit(2)
                        }.font(.system(size: 11, design: .monospaced))
                    }
                }
            }.padding(16)
        }
        .sheet(item: $editing) { r in
            // Saving replaces the rule with the same id, or appends it if it's new.
            RuleEditor(rule: r, isNew: isNew) { saved in
                if let i = e.rules.firstIndex(where: { $0.id == saved.id }) { e.rules[i] = saved } else { e.rules.append(saved) }
                editing = nil
            } cancel: { editing = nil }
        }
    }
}

/// Sheet for one rule. Works on a private copy, so Cancel discards every change; Save hands the edited copy back.
struct RuleEditor: View {
    @State var rule: Rule
    var isNew: Bool
    var save: (Rule) -> Void
    var cancel: () -> Void

    var body: some View {
        Form {
            TextField("Name", text: $rule.name)
            Picker("Watch", selection: $rule.target) { ForEach(Rule.Target.allCases) { Text($0.rawValue).tag($0) } }
            TextField(rule.target == .app ? "App name contains (empty = any app)" : "Process name contains (empty = any process)", text: $rule.match)
            Picker("Metric", selection: $rule.metric) { ForEach(Rule.Metric.allCases) { Text($0.rawValue).tag($0) } }
            // The threshold is in the unit named by the metric: CPU % of one core, memory GB, disk/network MB/s, energy W.
            TextField("Above", value: $rule.threshold, format: .number)
            TextField("For at least (minutes)", value: $rule.minutes, format: .number)
            Picker("Then", selection: $rule.action) { ForEach(Rule.Action.allCases) { Text($0.rawValue).tag($0) } }
            if rule.action == .command {
                TextField("Command (/bin/sh)", text: $rule.command)
                Text("Runs with FD_RULE, FD_SUBJECT, FD_PIDS, FD_METRIC and FD_VALUE in its environment.").font(.caption).foregroundStyle(.secondary)
            }
            if rule.action.isDestructive {
                Label("This \(rule.action == .suspend ? "suspends" : "quits") matching processes automatically, without asking. Unsaved work in them can be lost.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            // Cooldown is per rule and subject, so one app firing doesn't silence the rule for other apps.
            TextField("Don't repeat within (minutes)", value: $rule.cooldownMinutes, format: .number)
            // Live plain-English preview of the rule as configured.
            Text(rule.sentence).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                Button(isNew ? "Add Rule" : "Save") { save(rule) }.keyboardShortcut(.defaultAction)
                    .disabled(rule.name.isEmpty || (rule.action == .command && rule.command.isEmpty))
            }
        }
        .padding(20).frame(width: 520)
    }
}
