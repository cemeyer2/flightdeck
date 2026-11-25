import Foundation
import Security
import FlightDeckHelperProtocol

/// The helper's view of Authorization Services, behind a protocol so the gating rules are testable with a fake.
public protocol AuthorizationAuthority: AnyObject {
    func storedRule(_ right: String) -> [String: Any]?
    func setRule(_ right: String, _ rule: [String: Any]) -> Bool
    func removeRule(_ right: String) -> Bool
    /// Non-interactive: rebuilds the app's authorization from its external form and checks `right` with
    /// ExtendRights only, then frees the rebuilt reference.
    func verify(externalForm: Data, right: String) -> Bool
}

/// The real Security API adapter. Runs as root in the helper; not unit-tested.
public final class SystemAuthorizationAuthority: AuthorizationAuthority {
    public init() {}

    public func storedRule(_ right: String) -> [String: Any]? {
        var dict: CFDictionary?
        guard AuthorizationRightGet(right, &dict) == errAuthorizationSuccess else { return nil }
        return dict as? [String: Any]
    }

    public func setRule(_ right: String, _ rule: [String: Any]) -> Bool {
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return false }
        defer { AuthorizationFree(ref, []) }
        return AuthorizationRightSet(ref, right, rule as CFDictionary, HelperRight.description as CFString, nil, nil)
            == errAuthorizationSuccess
    }

    public func removeRule(_ right: String) -> Bool {
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return false }
        defer { AuthorizationFree(ref, []) }
        // Already gone counts as removed.
        return AuthorizationRightRemove(ref, right) == errAuthorizationSuccess || storedRule(right) == nil
    }

    public func verify(externalForm: Data, right: String) -> Bool {
        guard externalForm.count == kAuthorizationExternalFormLength else { return false }
        var ext = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &ext.bytes) { dst in _ = externalForm.copyBytes(to: dst) }
        var ref: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&ext, &ref) == errAuthorizationSuccess, let ref else { return false }
        defer { AuthorizationFree(ref, []) }
        return right.withCString { name -> Bool in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { p -> Bool in
                var rights = AuthorizationRights(count: 1, items: p)
                return AuthorizationCopyRights(ref, &rights, nil, [.extendRights], nil) == errAuthorizationSuccess
            }
        }
    }
}

public enum RightRegistrar {
    /// Makes sure the stored right is exactly ours, rewriting a missing or different one. false = couldn't set it,
    /// so the app must not prompt (an undefined right is judged by authd's default rule, not this one).
    public static func ensure(_ a: AuthorizationAuthority) -> Bool {
        if HelperRight.matches(stored: a.storedRule(HelperIDs.rightName)) { return true }
        guard a.setRule(HelperIDs.rightName, HelperRight.rule) else { return false }
        return HelperRight.matches(stored: a.storedRule(HelperIDs.rightName))
    }
}
