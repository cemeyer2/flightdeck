import Foundation
import UserNotifications
import FlightdeckCore

/// Turns sustained findings into macOS notifications: once per occurrence, only after the condition has
/// lasted `alertAfterMinutes`, and at most once per `cooldown` for the same finding.
@MainActor
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()
    static let cooldown: TimeInterval = 30 * 60

    var enabled: Bool { UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true }
    var minSeverity: Int { UserDefaults.standard.object(forKey: "alertMinSeverity") as? Int ?? 2 }
    /// Finding ids the user muted (alerts only; findings still show).
    var muted: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mutedFindings") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "mutedFindings") }
    }
    var after: TimeInterval { (UserDefaults.standard.object(forKey: "alertAfterMinutes") as? Double ?? 2) * 60 }

    private var notifiedSince: [String: Date] = [:]   // finding id -> the occurrence we already notified about
    private var lastSent: [String: Date] = [:]
    /// Navigation target for a clicked notification.
    var onOpen: ((String?) -> Void)?
    private var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : .current() }

    func start() {
        guard let center else { return }   // not running from an app bundle (e.g. `swift run`)
        center.delegate = self
        if enabled { center.requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    func requestPermission() { center?.requestAuthorization(options: [.alert, .sound]) { _, _ in } }

    func evaluate(_ findings: [Finding], now: Date) {
        let ids = Set(findings.map(\.id))
        notifiedSince = notifiedSince.filter { ids.contains($0.key) }
        guard enabled, let center else { return }
        let muted = self.muted
        for f in findings where f.severity.rawValue >= minSeverity && now.timeIntervalSince(f.since) >= after && !muted.contains(f.id) {
            guard notifiedSince[f.id] != f.since else { continue }
            notifiedSince[f.id] = f.since
            if let last = lastSent[f.id], now.timeIntervalSince(last) < Self.cooldown { continue }
            lastSent[f.id] = now
            let c = UNMutableNotificationContent()
            c.title = f.severity == .warning ? "Warning" : "Caution"
            c.subtitle = f.title
            c.body = (f.detail ?? "") + " (for \(shortDuration(now.timeIntervalSince(f.since))))"
            c.userInfo = ["destination": f.destination ?? ""]
            c.threadIdentifier = f.id
            center.add(UNNotificationRequest(identifier: "\(f.id)-\(Int(f.since.timeIntervalSince1970))", content: c, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let d = response.notification.request.content.userInfo["destination"] as? String
        await MainActor.run { onOpen?(d?.isEmpty == false ? d : nil) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
