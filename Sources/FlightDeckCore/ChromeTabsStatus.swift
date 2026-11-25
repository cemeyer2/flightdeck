import Foundation
// Chrome tabs: the one status line Settings shows, worked out from plain facts so every case is testable. The first
// matching rule wins: off; not a bundled app; the socket couldn't open; the app can't stay where it is; an extension
// speaking another protocol; a newer bundled extension Chrome hasn't reloaded; nothing installed yet; waiting for the
// extension; connected.

public enum ChromeTabsStatus: Equatable, Sendable {
    case off
    case unbundled
    case moveToApplications(reason: String)
    case notSetUp
    case waiting
    case connected(tabs: Int)
    case needsUpdating
    case reloadNeeded(bundled: String)
    case error(String)

    public static let moveReason = "Move FlightDeck to Applications to use Chrome tabs"

    /// - `bundledVersion`: the extension inside the app (nil for a `swift build` run, which has none).
    /// - `stableVersion`: the copy the user loads in Chrome (nil when not installed).
    /// - `relocatable`: false when the app runs translocated or from a read-only or removable volume (a mounted DMG).
    /// - `hellos`: one per connected extension (Chrome profile).
    public static func compute(enabled: Bool, bundledVersion: String?, stableVersion: String?, manifestPresent: Bool,
                               relocatable: Bool, hellos: [ChromeTabStore.Hello], tabCount: Int, listenerError: String?) -> ChromeTabsStatus {
        guard enabled else { return .off }
        guard let bundled = bundledVersion else { return .unbundled }
        if let listenerError { return .error(listenerError) }
        guard relocatable else { return .moveToApplications(reason: moveReason) }
        if hellos.contains(where: { $0.protocolVersion != ChromeTabsConstants.protocolVersion }) { return .needsUpdating }
        let behind = hellos.contains { ChromeExtensionInstall.isVersion(bundled, newerThan: $0.extensionVersion) }
        if behind || stableVersion.map({ ChromeExtensionInstall.isVersion(bundled, newerThan: $0) }) == true { return .reloadNeeded(bundled: bundled) }
        if hellos.isEmpty && (stableVersion == nil || !manifestPresent) { return .notSetUp }
        if hellos.isEmpty { return .waiting }
        return .connected(tabs: tabCount)
    }

    public var text: String {
        switch self {
        case .off: return "Off"
        case .unbundled: return "Run from a bundled FlightDeck.app to set up Chrome tabs"
        case .moveToApplications(let reason): return reason
        case .notSetUp: return "Not set up"
        case .waiting: return "Waiting for the extension"
        case .connected(let n): return "Connected, \(n) tab\(n == 1 ? "" : "s")"
        case .needsUpdating: return "Extension needs updating"
        case .reloadNeeded: return "Extension updated — click Reload for \(ChromeTabsConstants.extensionName) in chrome://extensions"
        case .error(let message): return message
        }
    }
}
