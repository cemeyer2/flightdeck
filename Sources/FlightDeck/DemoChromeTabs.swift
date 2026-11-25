// Demo mode's Chrome tabs: invented tab labels for the demo Google Chrome's helper processes, so screenshots can show
// renderer rows named after their tabs. Nothing here comes from a real browser; demo mode never opens the tab socket.
import Foundation
import FlightDeckCore

enum DemoChromeTabs {
    private static func tab(_ host: String, _ title: String, active: Bool = false, audible: Bool = false, last: Double) -> ChromeTabEntry {
        ChromeTabEntry(kind: .tab, host: host, title: title, url: "https://\(host)/", active: active, audible: audible, lastAccessed: last)
    }

    /// Labels for the demo Chrome's helpers in pid order: one busy video tab, a renderer shared by three tabs, an ad
    /// frame from another site, and an extension process.
    static let labels: [ChromeTabAttribution] = [
        ChromeTabAttribution(entries: [tab("youtube.com", "Lofi beats to study to", active: true, audible: true, last: 9)], isExtensionProcess: false),
        ChromeTabAttribution(entries: [tab("docs.google.com", "Q3 planning", last: 8), tab("docs.google.com", "Team notes", last: 5),
                                       tab("calendar.example", "Week of Nov 24", last: 3)], isExtensionProcess: false),
        ChromeTabAttribution(entries: [ChromeTabEntry(kind: .frame(inTabHost: "news.example"), host: "ads.example.net", title: "", url: "",
                                                      active: false, audible: false, lastAccessed: 2)], isExtensionProcess: false),
        ChromeTabAttribution(entries: [], isExtensionProcess: true),
    ]

    static func attribution(for processes: [ProcessSample]) -> [ProcessIdentity: ChromeTabAttribution] {
        let helpers = processes.filter { $0.path.contains("/Google Chrome.app/") && $0.name != "Google Chrome" }.sorted { $0.pid < $1.pid }
        return Dictionary(uniqueKeysWithValues: zip(helpers.map(\.identity), labels))
    }
}
