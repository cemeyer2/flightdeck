import Foundation

/// The administrator right the helper registers in the authorization database. A full rule rather than a reference
/// to the built-in authenticate-admin rule, which is `shared` (other processes in the session could gain rights
/// from its credential) and has `timeout = 0` (the helper's non-interactive re-check would fail right after the
/// prompt). "Until FlightDeck quits" comes from the app holding its authorization in memory, not from a timeout.
public enum HelperRight {
    public static let description = "FlightDeck wants to read system-wide details about processes, sockets and settings."

    public static var rule: [String: Any] {
        ["class": "user", "group": "admin", "authenticate-user": true, "shared": false,
         "session-owner": false, "allow-root": false, "comment": description]
    }

    /// Compares only the keys this rule sets (authd adds its own, like "created" and "version"). A stored
    /// "timeout" of any value means the rule isn't ours.
    public static func matches(stored: [String: Any]?) -> Bool {
        guard let stored, stored["timeout"] == nil else { return false }
        for (k, v) in rule {
            guard let s = stored[k] else { return false }
            if let b = v as? Bool {
                guard let sb = (s as? NSNumber)?.boolValue ?? (s as? Bool), sb == b else { return false }
            } else if let str = v as? String {
                guard s as? String == str else { return false }
            }
        }
        return true
    }
}
