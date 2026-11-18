// A small wrapper over the Keychain's generic-password items (Security framework), used for UniFi credentials: the API
// key, or the classic username/password. Secrets are never written to UserDefaults or logs. The service name is a
// parameter so tests can use their own and delete it afterwards.
import Foundation
import Security

public struct Keychain: Sendable {
    public let service: String
    public init(service: String) { self.service = service }

    public enum Failure: Error, CustomStringConvertible {
        case status(OSStatus)
        public var description: String {
            switch self {
            case .status(let s): return (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)"
            }
        }
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Stores (or replaces) the secret for `account`. Items are only readable while the Mac is unlocked and never
    /// migrate to another device.
    public func set(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrLabel as String] = "FlightDeck (\(service))"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    /// The secret for `account`, or nil if there is none (or it can't be read).
    public func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Deletes the secret for `account`; deleting one that doesn't exist is not an error.
    public func delete(_ account: String) throws {
        let s = SecItemDelete(query(account) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw Failure.status(s) }
    }

    /// Deletes every item of this service (used by "Forget" and by tests to clean up).
    public func deleteAll() throws {
        let s = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw Failure.status(s) }
    }
}
