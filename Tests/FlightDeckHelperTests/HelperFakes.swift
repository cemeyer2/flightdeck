import Foundation
@testable import FlightDeckHelperProtocol
@testable import FlightDeckHelperCore

final class FakeAuthority: AuthorizationAuthority {
    var rules: [String: [String: Any]] = [:]
    var setCount = 0
    var failSet = false
    var removed: [String] = []
    var validForms: Set<Data> = []
    var verifyCount = 0

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
        verifyCount += 1
        return right == HelperIDs.rightName && externalForm.count == 32 && validForms.contains(externalForm)
    }
}

final class FakeProcessReader: ProcessReading {
    var identities: [Int32: HelperProcessID] = [:]
    /// When non-empty, identity(of:) returns these in order (one per call) instead of `identities`.
    var identitySequence: [HelperProcessID] = []
    var names: [Int32: String] = [:]
    var usage: [Int32: HelperRusage] = [:]
    var contentsToReturn = HelperProcessContents(args: ["--secret"], env: ["K=V"])

    func identity(of pid: Int32) -> HelperProcessID? {
        if !identitySequence.isEmpty { return identitySequence.removeFirst() }
        return identities[pid]
    }
    func name(of pid: Int32) -> String? { names[pid] }
    func rusage(of pid: Int32) -> HelperRusage? { usage[pid] }
    func contents(of pid: Int32, parts: Set<DetailPart>) -> HelperProcessContents { contentsToReturn }
}

final class FakeRunner: ToolRunning {
    var results: [HelperTool: ToolResult] = [:]
    var fallback: ToolResult = .output("")
    var calls: [HelperTool] = []
    func run(_ tool: HelperTool) -> ToolResult {
        calls.append(tool)
        return results[tool] ?? fallback
    }
}

final class MemorySettings: HelperSettingsStoring {
    var agentContents = false
    var removed = false
    func removeAll() { agentContents = false; removed = true }
}
