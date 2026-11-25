import Foundation
import FlightDeckHelperProtocol

/// What MCP may get from the root helper right now. Counters flow while unlocked; contents (arguments, environment,
/// files, stacks of other users' processes) only with the separate agent setting on as well.
public struct HelperMCPAccess: Sendable, Equatable {
    public var state: HelperAccessState
    public var agentContents: Bool
    public init(state: HelperAccessState, agentContents: Bool) { self.state = state; self.agentContents = agentContents }
    public static let off = HelperMCPAccess(state: .off, agentContents: false)
    /// Contents of other users' processes may be served.
    public var contentsAllowed: Bool { state == .unlocked && agentContents }
}

extension MCPTools {
    static let unlockNote = "unlock in FlightDeck to include all users"
    static let contentsOffNote = "turn on agent access to process details in FlightDeck Settings"

    /// ("helper", "off" | "locked" | "unlocked"), plus the unlock note unless unlocked.
    func helperPairs(_ a: HelperMCPAccess) -> [(String, JSON?)] {
        [("helper", .str(a.state.rawValue)), ("helper_note", a.state == .unlocked ? nil : .str(Self.unlockNote))]
    }

    /// Adds the helper pairs to a tool's JSON object (for outputs built by static helpers).
    func withHelper(_ j: JSON, _ a: HelperMCPAccess) -> JSON {
        guard case .object(let pairs) = j else { return j }
        return .object(pairs + helperPairs(a).compactMap { k, v in v.map { (k, $0) } })
    }
}
