// State behind the Weekly Report page, and the service that keeps the saved reports current and sends the opt-in
// weekly notification. Building happens in FlightDeckCore (WeeklyReportBuilder) on a detached task: when the page
// appears, and at most once a day in the background (checked every 15 minutes and at wake). Demo mode shows invented
// weeks and never reads, saves or notifies.
import SwiftUI
import FlightDeckCore

@MainActor
final class WeeklyReportModel: ObservableObject {
    /// The app's model (live), shared by the page and the notification (which picks the week the page opens on).
    static let shared: WeeklyReportModel = Demo.isEnabled ? demo() : WeeklyReportModel(store: WeeklyReportStore(dir: WeeklyReportStore.defaultDirectory))

    @Published private(set) var reports: [WeeklyReport] = []
    /// The selected week's id; nil = the newest (this week so far).
    @Published var selection: String?
    @Published private(set) var loading = false
    @Published private(set) var loadedAt: Date?
    /// Demo and preview models never read the machine.
    let fixed: Bool
    let store: WeeklyReportStore

    init(store: WeeklyReportStore) { self.store = store; fixed = false; reports = store.all() }
    /// A model over reports that are already built (demo data, or a load finished before an off-screen render).
    init(preview: [WeeklyReport], selection: String? = nil) {
        store = WeeklyReportStore(preview: preview); fixed = true; reports = preview; self.selection = selection; loadedAt = Date()
    }
    static func demo() -> WeeklyReportModel { let d = DemoWeekly.reports(); return WeeklyReportModel(preview: d.reports, selection: d.busy) }

    var selected: WeeklyReport? { reports.first { $0.id == selection } ?? reports.first }
    /// The report for the week before `r`, for the deltas (nil when none was saved or built).
    func previous(of r: WeeklyReport) -> WeeklyReport? { let id = r.week.previous().id; return reports.first { $0.id == id } }

    /// Rebuilds the weeks that aren't final yet, saves them and republishes.
    func load(engine: Engine) async {
        guard !fixed, !loading else { return }
        loading = true; defer { loading = false }
        let gather = Self.gatherer(engine)
        let store = self.store
        reports = await Task.detached(priority: .utility) { WeeklyReports.refresh(store: store, sources: gather()) }.value
        loadedAt = Date()
    }

    /// Takes what only the main actor has (the Flight Log, the live disk reading and trend) and returns a function that
    /// reads the rest (daily log, battery history, boots and panics, destinations) off the main thread.
    static func gatherer(_ e: Engine) -> @Sendable () -> WeeklySources {
        let incidents = e.incidents, log = e.dailyLog, fullDays = e.diskFullDays
        let snap = e.liveSnapshot ?? (e.mode == .live ? e.current : nil)
        let storage = snap.flatMap(Analyzer.startupVolume).map { WeeklyStorage(readAt: snap!.time, used: $0.used, capacity: $0.capacity, fullInDays: fullDays) }
        let tracker = DestinationService.tracker
        return {
            var s = WeeklySources(now: Date())
            s.days = log.history().days
            s.battery = BatteryHistory.merge(log.batteryHistory().days)
            s.incidents = incidents
            s.storage = storage
            // Read-only copy: the Restarts page owns boots.json; nothing here writes it or queries the unified log.
            s.add(RestartsCollector.collect(store: BootStore(dir: DailyLog.defaultDirectory, readOnly: true), queryLog: .none))
            if let tracker, let store = tracker.store {
                let today = tracker.today()
                let days = store.days(from: s.now.addingTimeInterval(-Double(DestinationStore.retentionDays) * 86_400), to: s.now).filter { $0.start != today.start }
                s.destinationDays = days + [today]; s.known = tracker.known()
            }
            return s
        }
    }

    /// Synchronous build for UIBench's off-screen renders (ImageRenderer never runs `.task`) from this Mac's saved data,
    /// read only (a daily log that never ingests never writes; the incident log is never saved), into an in-memory store
    /// seeded with the saved reports, so a render never writes. Call before building views.
    static func loadedForRender(engine: Engine) -> WeeklyReportModel {
        var s = WeeklySources(now: Date())
        let log = DailyLog(dir: DailyLog.defaultDirectory)
        s.days = log.history().days
        s.battery = log.batteryHistory().days
        s.incidents = IncidentLog(url: IncidentLog.defaultURL).incidents
        s.add(RestartsCollector.collect(store: BootStore(dir: DailyLog.defaultDirectory, readOnly: true), queryLog: .none))
        let dest = DestinationStore(dir: DestinationStore.defaultDirectory, readOnly: true)
        s.destinationDays = dest.days(from: s.now.addingTimeInterval(-Double(DestinationStore.retentionDays) * 86_400), to: s.now)
        s.known = dest.loadKnown()
        if let snap = engine.current, let v = Analyzer.startupVolume(snap) {
            s.storage = WeeklyStorage(readAt: snap.time, used: v.used, capacity: v.capacity, fullInDays: engine.diskFullDays)
        }
        let memory = WeeklyReportStore(preview: WeeklyReportStore(dir: WeeklyReportStore.defaultDirectory, readOnly: true).all())
        return WeeklyReportModel(preview: WeeklyReports.refresh(store: memory, sources: s))
    }
}

/// Keeps the saved reports current (at most once a day) and posts the opt-in weekly notification when it's due.
@MainActor
final class WeeklyReportService {
    static let shared = WeeklyReportService()
    static let builtKey = "weeklyReportBuiltDay"
    private weak var engine: Engine?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    var enabled: Bool { UserDefaults.standard.bool(forKey: WeeklySchedule.enabledKey) }
    var weekday: Int { UserDefaults.standard.object(forKey: WeeklySchedule.weekdayKey) as? Int ?? WeeklySchedule.defaultWeekday }
    var minutes: Int { UserDefaults.standard.object(forKey: WeeklySchedule.minutesKey) as? Int ?? WeeklySchedule.defaultMinutes }

    /// Called from ContentView's onAppear (idempotent). Never in demo mode or for a headless engine.
    func attach(_ e: Engine) {
        guard !Demo.isEnabled, !e.headless, engine == nil else { return }
        engine = e
        // A minute after launch (not during the launch's busiest seconds), then every 15 minutes and at each wake.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.check() } }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Give the network and the sampler a minute to settle after waking.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { Task { @MainActor in self?.check() } }
        }
    }

    /// Turning the notification on starts the schedule from now, so no old week is sent at once.
    static func scheduleChanged() {
        if UserDefaults.standard.bool(forKey: WeeklySchedule.enabledKey) { UserDefaults.standard.set(Date(), forKey: WeeklySchedule.deliveredKey) }
    }

    func check() {
        guard let e = engine else { return }
        let d = UserDefaults.standard, now = Date()
        let due: Date? = enabled ? WeeklySchedule.due(now: now, lastDelivered: d.object(forKey: WeeklySchedule.deliveredKey) as? Date, weekday: weekday, minutes: minutes) : nil
        if enabled, d.object(forKey: WeeklySchedule.deliveredKey) == nil { d.set(now, forKey: WeeklySchedule.deliveredKey) }
        let today = Self.dayKey(now)
        guard due != nil || d.string(forKey: Self.builtKey) != today else { return }
        d.set(today, forKey: Self.builtKey)
        let model = WeeklyReportModel.shared
        Task {
            await model.load(engine: e)
            guard let due else { return }
            d.set(now, forKey: WeeklySchedule.deliveredKey)
            let week = WeeklySchedule.week(for: due)
            guard let r = model.reports.first(where: { $0.id == week.id }) else { return }
            let digest = WeeklyDigest.make(r, previous: model.previous(of: r))
            model.selection = r.id   // a click on the notification opens this week
            Alerts.shared.post(title: "Weekly Report: \(digest.headline)", body: digest.notificationBody, destination: Destination.weeklyReport.rawValue)
        }
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
