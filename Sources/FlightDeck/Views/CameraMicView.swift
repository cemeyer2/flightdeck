// "Camera & Mic" destination, the privacy watch: what's using the camera and microphone right now and by which app,
// then a timeline (today, 7 or 30 days) and the session list, filterable by app and device. Sessions at unusual hours
// (midnight to 6 a.m.), while the screen was locked or the Mac idle, and an app's first use are highlighted. Every app
// name carries how it was identified, so a guess reads as "likely X" and an unknown stays "Unknown app".
import SwiftUI
import FlightDeckCore

/// The span the timeline and list cover.
enum CameraMicRange: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 days", month = "30 days"
    var id: String { rawValue }
    var days: Int { switch self { case .today: 1; case .week: 7; case .month: 30 } }
    func start(_ now: Date, _ cal: Calendar = .current) -> Date {
        cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: now))!
    }
}

struct CameraMicView: View {
    @ObservedObject var model: CameraMicModel
    @Environment(\.palette) var p
    @AppStorage("cameraMicRange") private var range: CameraMicRange = .week
    @State private var appFilter = "all"      // "all" or SensorApp.key ("?" = unknown app)
    @State private var deviceFilter = "all"   // "all", a SensorKind raw value, or "dev:" + device label
    @State private var confirmClear = false

    /// `fixedRange` pins the range (UIBench renders), leaving the saved choice alone.
    var fixedRange: CameraMicRange?
    @MainActor init(model: CameraMicModel? = nil, range: CameraMicRange? = nil) { self.model = model ?? .shared; fixedRange = range }

    static func appKey(_ s: SensorSession) -> String { s.confidence == .confirmed ? (s.app?.key ?? "?") : "?" + (s.app?.key ?? "") }

    func matches(_ s: SensorSession) -> Bool {
        if appFilter != "all" && Self.appKey(s) != appFilter { return false }
        if deviceFilter.hasPrefix("dev:") { return s.devices.contains(String(deviceFilter.dropFirst(4))) }
        return deviceFilter == "all" || s.kind.rawValue == deviceFilter
    }

    var body: some View {
        let now = Date()
        let range = fixedRange ?? self.range
        let from = range.start(now)
        let inRange = model.sessions.filter { ($0.end ?? now) >= from }
        let shown = inRange.filter(matches)
        VStack(spacing: 0) {
            filterBar(inRange)
            MaybeScroll {
                VStack(alignment: .leading, spacing: 12) {
                    Text(privacyNote).font(.caption).foregroundStyle(p.dim)
                    HStack(alignment: .top, spacing: 12) {
                        LiveSensorCard(kind: .camera, model: model)
                        LiveSensorCard(kind: .microphone, model: model)
                    }
                    CameraMicTimeline(sessions: shown, range: range, now: now)
                    CameraMicSessionList(sessions: shown.reversed(), firstSeen: model.firstSeen, now: now,
                                         filterApp: { appFilter = $0 })
                }.padding(14)
            }
        }
        .confirmationDialog("Clear the Camera & Mic history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("Deletes every recorded session and the list of apps seen before, so every app's next use counts as a first use. Sessions in progress continue.")
        }
    }

    var privacyNote: String {
        let base = "FlightDeck records only that a camera or microphone was in use (device, app, times), never audio or video. The history stays on this Mac, in Application Support, for \(CameraMicStore.retentionDays) days."
        if model.preview { return "Demo data: invented sessions, nothing about this Mac. " + base }
        guard let since = model.live.since else { return base + " Not watching right now: the state above is a single reading." }
        return base + " Watching since \(since.formatted(date: .abbreviated, time: .shortened)); use while FlightDeck wasn't running isn't seen."
    }

    /// App choices from the sessions in range, by total time; guesses and unknowns are their own entries.
    static func appChoices(_ sessions: [SensorSession]) -> [String: (label: String, secs: TimeInterval)] {
        var apps: [String: (label: String, secs: TimeInterval)] = [:]
        for s in sessions { apps[appKey(s), default: (s.appLabel, 0)].secs += s.duration() }
        return apps
    }

    @ViewBuilder func filterBar(_ sessions: [SensorSession]) -> some View {
        let apps = Self.appChoices(sessions)
        let devices = Array(Set(sessions.flatMap(\.devices))).sorted()
        HStack(spacing: 12) {
            Picker("", selection: $range) { ForEach(CameraMicRange.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            Picker("App", selection: $appFilter) {
                Text("All apps").tag("all")
                ForEach(apps.sorted { $0.value.secs > $1.value.secs }, id: \.key) { k, v in Text(v.label).tag(k) }
                if appFilter != "all" && apps[appFilter] == nil { Text("(no sessions in range)").tag(appFilter) }
            }.frame(maxWidth: 220)
            Picker("Device", selection: $deviceFilter) {
                Text("All devices").tag("all")
                Text("Cameras").tag(SensorKind.camera.rawValue); Text("Microphones").tag(SensorKind.microphone.rawValue)
                if !devices.isEmpty { Divider() }
                ForEach(devices, id: \.self) { Text($0).tag("dev:" + $0) }
                if deviceFilter.hasPrefix("dev:") && !devices.contains(String(deviceFilter.dropFirst(4))) { Text("(no sessions in range)").tag(deviceFilter) }
            }.frame(maxWidth: 260)
            Spacer()
            Button("Clear History…") { confirmClear = true }.disabled(model.sessions.isEmpty)
        }.padding(10)
    }
}

/// Now: is this kind of device in use, which devices, and which app (with how that's known).
struct LiveSensorCard: View {
    let kind: SensorKind
    @ObservedObject var model: CameraMicModel
    @Environment(\.palette) var p

    var body: some View {
        let l = model.live
        let inUse = l.inUse(kind)
        let open = model.open(kind)
        Panel(title: kind.title, trailing: inUse ? "IN USE" : "not in use") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kind.icon).font(.system(size: 20))
                    .foregroundStyle(inUse ? p.warn : p.dim).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    if !inUse {
                        Text(idleText(l)).foregroundStyle(p.dim)
                    }
                    ForEach(open) { s in
                        HStack(spacing: 6) {
                            if let path = s.app?.path { AppIcon(path: path + "/").frame(width: 14, height: 14) }
                            Text(s.appLabel).font(.system(size: 13, weight: .semibold))
                            Text("since \(s.start.formatted(date: .omitted, time: .shortened))\(s.startObserved ? "" : " or earlier")")
                                .foregroundStyle(p.dim)
                        }
                        Text(s.how).font(.caption).foregroundStyle(p.dim)
                    }
                    if inUse, open.isEmpty { Text("App not known yet").foregroundStyle(p.dim) }
                    let devs = (l.running[kind] ?? []).map(\.label)
                    if !devs.isEmpty { Text(devs.joined(separator: " · ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.dim) }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func idleText(_ l: CameraMicLive) -> String {
        if kind == .camera { return l.cameras.isEmpty ? "No camera connected." : "\(l.cameras.map(\.name).joined(separator: ", ")) idle." }
        return l.perProcessAudio ? "No app is reading a microphone." : "No input device is running (macOS 14.2+ also shows which process)."
    }
}
