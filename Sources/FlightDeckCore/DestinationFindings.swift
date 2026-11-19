import Foundation
// Destinations, part 8: the opt-in "an app contacted a new destination" alert (Settings › Alerts), as ordinary
// Findings so it reaches the banner, notifications (with mutes), the menu bar caution light and the Flight Log.
//
// Rate limit: first contacts are grouped per app into one-hour windows. The first new destination opens a window and
// its finding; more new destinations within the hour join the same finding (same id and start, so Alerts doesn't
// notify again), and the finding lasts until the window ends. So each app notifies at most once an hour.
// Defaults keep it quiet: off unless turned on; internet destinations only; web browsers (which contact new sites all
// day) ignored. "New" means not contacted by this app in the last 30 days, after a day of watching it.

public struct DestinationAlertSettings: Sendable, Equatable {
    public var enabled: Bool
    public var ignoreBrowsers: Bool
    public var includeLocal: Bool
    public init(enabled: Bool = false, ignoreBrowsers: Bool = true, includeLocal: Bool = false) {
        self.enabled = enabled; self.ignoreBrowsers = ignoreBrowsers; self.includeLocal = includeLocal
    }

    public static let enabledKey = "destinationsAlertNew"
    public static let browsersKey = "destinationsAlertIgnoreBrowsers"
    public static let localKey = "destinationsAlertLocal"
    public static func load(_ d: UserDefaults = .standard) -> DestinationAlertSettings {
        DestinationAlertSettings(enabled: d.bool(forKey: enabledKey),
                                 ignoreBrowsers: d.object(forKey: browsersKey) as? Bool ?? true,
                                 includeLocal: d.bool(forKey: localKey))
    }
}

public enum DestinationFindings {
    /// The Destination raw value of the page.
    public static let destination = "Destinations"
    /// Length of one app's alert window.
    public static let window: TimeInterval = 3600

    /// Web browsers and the WebKit processes that do Safari's networking, matched by app name or process name.
    static let browsers: Set<String> = ["Safari", "Safari Technology Preview", "Google Chrome", "Google Chrome Canary", "Chromium",
                                        "Firefox", "Firefox Developer Edition", "Arc", "Microsoft Edge", "Brave Browser", "Opera",
                                        "Vivaldi", "Orion", "Zen", "Zen Browser", "DuckDuckGo", "com.apple.WebKit.Networking",
                                        "com.apple.Safari.SafeBrowsing.Service"]
    public static func isBrowser(_ appName: String) -> Bool { browsers.contains(appName) }

    /// Findings for first contacts in the last `window`. `contacts` oldest first (DestinationTracker.newContacts).
    public static func findings(_ contacts: [DestinationTracker.NewContact], settings: DestinationAlertSettings, now: Date) -> [Finding] {
        guard settings.enabled else { return [] }
        var windows: [String: (start: Date, name: String, dests: [String])] = [:]
        var out: [Finding] = []
        func emit(_ app: String, _ w: (start: Date, name: String, dests: [String])) {
            guard now.timeIntervalSince(w.start) < window else { return }
            let shown = w.dests.prefix(3).joined(separator: ", ") + (w.dests.count > 3 ? " and \(w.dests.count - 3) more" : "")
            out.append(Finding(id: "privacy:dest:\(app):\(Int(w.start.timeIntervalSince1970))", severity: .caution, icon: "point.3.connected.trianglepath.dotted",
                               title: w.dests.count == 1 ? "\(w.name) contacted a new destination: \(w.dests[0])"
                                                        : "\(w.name) contacted \(w.dests.count) new destinations",
                               detail: "First contact at \(w.start.formatted(date: .omitted, time: .shortened)): \(shown). Not contacted by this app in the last \(DestinationStore.retentionDays) days. Names are from reverse DNS where available.",
                               since: w.start, destination: destination))
        }
        for c in contacts where now.timeIntervalSince(c.at) < 2 * window {
            if !settings.includeLocal && c.scope.isLocal { continue }
            if settings.ignoreBrowsers && isBrowser(c.appName) { continue }
            if let w = windows[c.app], c.at.timeIntervalSince(w.start) < window {
                if !w.dests.contains(c.dest) { windows[c.app]?.dests.append(c.dest) }
            } else {
                if let w = windows[c.app] { emit(c.app, w) }   // an older window that has ended
                windows[c.app] = (c.at, c.appName, [c.dest])
            }
        }
        for (app, w) in windows { emit(app, w) }
        return out.sorted { $0.since < $1.since }
    }
}
