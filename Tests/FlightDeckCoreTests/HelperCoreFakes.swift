import Foundation
@testable import FlightDeckCore
import FlightDeckHelperProtocol

/// A scriptable helper: replies keyed by request kind, an optional per-request handler, a delay that is honoured
/// against the caller's deadline, and a call log. Shared by every helper test in FlightDeckCoreTests.
final class FakeHelperClient: HelperClient, @unchecked Sendable {
    private let lock = NSLock()
    var replies: [String: HelperResponse] = [:]
    var handler: ((HelperRequest) -> HelperResponse?)?
    var delay: TimeInterval = 0
    var unreachable = false
    private(set) var calls: [HelperRequest] = []
    private(set) var authorizations: [Data?] = []
    private(set) var invalidations = 0

    func send(_ r: HelperRequest, authorization: Data?, deadline: TimeInterval) -> Result<HelperResponse, HelperClientError> {
        lock.lock()
        calls.append(r)
        authorizations.append(authorization)
        let d = delay, down = unreachable
        lock.unlock()
        if d > 0 {
            Thread.sleep(forTimeInterval: min(d, deadline))
            if d > deadline { return .failure(.timeout) }
        }
        if down { return .failure(.unreachable) }
        if let h = handler, let reply = h(r) { return .success(reply) }
        if let reply = replies[r.kind] { return .success(reply) }
        return .failure(.badReply)
    }

    func invalidate() { lock.lock(); invalidations += 1; lock.unlock() }

    func calls(of kind: String) -> [HelperRequest] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.kind == kind }
    }

    /// processRusage answered with `usage` for every requested identity.
    func echoRusage(_ usage: HelperRusage) {
        handler = { r in
            guard case .processRusage(let ids) = r else { return nil }
            return .rusage(ids.map { HelperRusageEntry(id: $0, rusage: usage) })
        }
    }
}

extension HelperSession {
    static let testAuthorization = Data(repeating: 0xAB, count: 32)

    /// A connected session that holds an unlock: hello ok with the right in place, status unlocked.
    static func unlockedForTests(_ fake: FakeHelperClient, agentContents: Bool = false,
                                 clock: @escaping () -> Date = Date.init) -> HelperSession {
        fake.replies["hello"] = .hello(HelperHello(version: HelperIDs.protocolVersion, rightInPlace: true, eligible: true))
        fake.replies["status"] = .status(HelperServiceStatus(unlocked: true, holderAlive: true, agentContents: agentContents))
        let s = HelperSession(client: fake, authorization: { testAuthorization }, clock: clock)
        s.connect()
        s.refreshStatus()
        return s
    }
}
