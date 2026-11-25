// macOS notifications for findings and rule actions. Engine calls `evaluate` on the main actor after every sample with
// the live findings plus diagnostic-report findings; rule actions call `post`. Settings live in user defaults.
import Foundation
import AppKit
import UserNotifications
import FlightDeckCore

/// Turns sustained findings into macOS notifications: once per occurrence, only after the condition has
/// lasted `alertAfterMinutes`, and at most once per `cooldown` for the same finding.
/// An "occurrence" is identified by the finding's `since` date: if a finding clears and comes back it is a new
/// occurrence, but the cooldown still suppresses it if the last notification for that id was under 30 minutes ago.
@MainActor
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()
    static let cooldown: TimeInterval = 30 * 60

    // Settings are read from UserDefaults on every use (rather than cached) so changes in Settings apply immediately.
    // Defaults here must match the @AppStorage defaults in SettingsView.
    var enabled: Bool { UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true }
    /// Minimum `Finding.Severity` raw value to notify for (2 = caution, 3 = warning).
    var minSeverity: Int { UserDefaults.standard.object(forKey: "alertMinSeverity") as? Int ?? 2 }
    /// Finding ids the user muted (alerts only; findings still show).
    /// Entries are finding ids ("cpu:/Applications/Xcode.app") or whole kinds ("kind:hang").
    var muted: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mutedFindings") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "mutedFindings") }
    }

    /// A finding's kind is its id up to the first ":" ("hang:123-456" → "hang"); ids without one are their own kind.
    static func kind(of id: String) -> String { id.split(separator: ":").first.map(String.init) ?? id }

    /// Readable names for kinds, for "Mute all … alerts".
    static func kindName(_ k: String) -> String {
        ["cpu": "busy-app", "gpu": "GPU-hog", "hang": "not-responding", "awake": "keeping-awake", "leak": "memory-growth",
         "wakeups": "wake-up", "report": "repeated crash/hang", "drive": "drive-health", "rule": "rule", "privacy": "camera & mic"][k] ?? k
    }

    /// Muted findings don't notify and don't light the annunciator, menu bar or Dock lamp.
    func isMuted(_ f: Finding) -> Bool { let m = muted; return m.contains(f.id) || m.contains("kind:" + Self.kind(of: f.id)) }

    /// Last time each exactly-muted finding was seen; per-instance mutes (a hang of one process, say) that haven't
    /// come back for 30 days are pruned so the list doesn't grow forever. Kind mutes are kept until unmuted.
    private func pruneMutes(seen ids: Set<String>, now: Date) {
        var seenAt = UserDefaults.standard.dictionary(forKey: "mutedSeen") as? [String: Double] ?? [:]
        let m = muted
        for id in m where !id.hasPrefix("kind:") && (ids.contains(id) || seenAt[id] == nil) { seenAt[id] = now.timeIntervalSince1970 }
        let stale = m.filter { !$0.hasPrefix("kind:") && now.timeIntervalSince1970 - (seenAt[$0] ?? 0) > 30 * 86_400 }
        if !stale.isEmpty { muted = m.subtracting(stale) }
        UserDefaults.standard.set(seenAt.filter { muted.contains($0.key) }, forKey: "mutedSeen")
    }
    /// How long a finding must have lasted before it notifies, in seconds.
    var after: TimeInterval { (UserDefaults.standard.object(forKey: "alertAfterMinutes") as? Double ?? 2) * 60 }

    private var notifiedSince: [String: Date] = [:]   // finding id -> the occurrence we already notified about
    /// When each finding id was last notified, for the cooldown. Unlike `notifiedSince`, kept after the finding clears.
    private var lastSent: [String: Date] = [:]
    /// Navigation target for a clicked notification (a Destination raw value, or nil to just show the main window).
    /// Set by MenuBarLabel or ContentView, whichever appears first.
    var onOpen: ((String?) -> Void)?
    /// UNUserNotificationCenter crashes when the process has no bundle identifier, so without one notifications are off.
    private var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : .current() }

    /// Called once at launch from the AppDelegate.
    func start() {
        guard let center else { return }   // not running from an app bundle (e.g. `swift run`)
        center.delegate = self
        // First launch asks from the welcome sheet, with context, instead of a bare prompt at startup.
        if enabled && UserDefaults.standard.bool(forKey: "welcomed") { center.requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    func requestPermission() { center?.requestAuthorization(options: [.alert, .sound]) { _, _ in } }

    /// Main actor, once per sample.
    func evaluate(_ findings: [Finding], now: Date) {
        let ids = Set(findings.map(\.id))
        // Forget occurrences that have ended, so a recurrence counts as new. Done even while alerts are disabled.
        notifiedSince = notifiedSince.filter { ids.contains($0.key) }
        guard enabled, let center else { return }
        pruneMutes(seen: ids, now: now)
        // Camera & mic alerts ("privacy:…") are events the user opted into one by one, not sustained problems: they
        // notify at once, whatever the severity floor and the "after it lasts" delay (a 10-second use would never last).
        for f in findings where (Self.kind(of: f.id) == "privacy" || f.severity.rawValue >= minSeverity && now.timeIntervalSince(f.since) >= after) && !isMuted(f) {
            // Mark the occurrence as handled before the cooldown check: an occurrence suppressed by the cooldown is not
            // notified later, even once the cooldown has passed.
            guard notifiedSince[f.id] != f.since else { continue }
            // Still in the cooldown: wait (don't mark it notified), so it's sent once the cooldown passes if it persists.
            if let last = lastSent[f.id], now.timeIntervalSince(last) < Self.cooldown { continue }
            notifiedSince[f.id] = f.since
            lastSent[f.id] = now
            let c = UNMutableNotificationContent()
            c.title = f.severity == .warning ? "Warning" : "Caution"
            c.subtitle = f.title
            c.body = (f.detail ?? "") + (Self.kind(of: f.id) == "privacy" ? "" : " (for \(shortDuration(now.timeIntervalSince(f.since))))")
            c.userInfo = ["destination": f.destination ?? ""]
            c.threadIdentifier = f.id
            // The identifier includes the occurrence start, so a repeat of the same occurrence replaces rather than stacks.
            center.add(UNNotificationRequest(identifier: "\(f.id)-\(Int(f.since.timeIntervalSince1970))", content: c, trigger: nil))
        }
    }

    /// A plain notification (rules), independent of finding severity settings.
    func post(title: String, body: String, destination: String? = "Rules") {
        guard let center else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.userInfo = ["destination": destination ?? ""]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// A notification that opens a release page when clicked (update checks). Unlike `post(title:body:destination:)`,
    /// this obeys the master Alerts switch and notification authorisation, and says whether it was actually posted.
    func post(title: String, body: String, url: URL, identifier: String) async -> Bool {
        guard enabled, let center else { return false }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return false }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.userInfo = ["url": url.absoluteString]
        do { try await center.add(UNNotificationRequest(identifier: identifier, content: c, trigger: nil)); return true } catch { return false }
    }

    // Delegate callbacks arrive off the main actor; hop back before navigating.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // A release page (update checks): re-validated here, so only this repo's releases on github.com ever open.
        if let s = response.notification.request.content.userInfo["url"] as? String, let u = URL(string: s), ReleaseInfo.isTrustedReleaseURL(u) {
            await MainActor.run { _ = NSWorkspace.shared.open(u) }
            return
        }
        let d = response.notification.request.content.userInfo["destination"] as? String
        await MainActor.run { onOpen?(d?.isEmpty == false ? d : nil) }
    }

    // Show banners even while FlightDeck is frontmost (by default macOS suppresses them for the active app).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
