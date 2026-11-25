import Foundation
@testable import FlightDeckHelperProtocol
@testable import FlightDeckHelperCore

final class FakeAuthority: AuthorizationAuthority {
    var rules: [String: [String: Any]] = [:]
    var setCount = 0
    var failSet = false
    var removed: [String] = []
    var validForms: Set<Data> = []

    func storedRule(_ right: String) -> [String: Any]? { rules[right] }
    func setRule(_ right: String, _ rule: [String: Any]) -> Bool {
        setCount += 1
        if failSet { return false }
        rules[right] = rule
        return true
    }
    func removeRule(_ right: String) -> Bool {
        removed.append(right)
        rules[right] = nil
        return true
    }
    func verify(externalForm: Data, right: String) -> Bool {
        right == HelperIDs.rightName && externalForm.count == 32 && validForms.contains(externalForm)
    }
}
