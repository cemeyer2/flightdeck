import Foundation
import FlightDeckHelperProtocol

// The app side of the optional root helper's XPC connection. Everything here is safe when the helper is off,
// missing or stuck: calls have a deadline, and repeated failures back off (HelperCallGate) so sampling never stalls.

/// Why a helper call gave no answer. Never carries the authorization bytes.
public enum HelperClientError: Error, Equatable, CustomStringConvertible {
    case unreachable, timeout, refused(HelperRefusal), badReply
    public var description: String {
        switch self {
        case .unreachable: return "the helper couldn't be reached"
        case .timeout: return "the helper didn't answer in time"
        case .refused(let r): return r.message
        case .badReply: return "the helper's reply wasn't recognised"
        }
    }
}

public protocol HelperClient: AnyObject, Sendable {
    /// Blocking, for at most `deadline` seconds. A `.refused` response comes back as a success; HelperSession turns it
    /// into `.refused`.
    func send(_ r: HelperRequest, authorization: Data?, deadline: TimeInterval) -> Result<HelperResponse, HelperClientError>
    func invalidate()
}

/// NSXPCConnection to the helper's privileged Mach service, which must itself be signed by this build's team.
/// Not unit-tested: it needs a registered, Developer ID-signed helper.
public final class XPCHelperClient: HelperClient, @unchecked Sendable {
    private let teamID: String
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init(teamID: String) { self.teamID = teamID }

    private func current() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: HelperIDs.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        c.setCodeSigningRequirement("anchor apple generic and identifier \"\(HelperIDs.machService)\" and certificate leaf[subject.OU] = \"\(teamID)\"")
        c.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.connection === c { self.connection = nil }
            self.lock.unlock()
        }
        c.resume()
        connection = c
        return c
    }

    public func send(_ r: HelperRequest, authorization: Data?, deadline: TimeInterval) -> Result<HelperResponse, HelperClientError> {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let proxy = current().remoteObjectProxyWithErrorHandler { _ in
            box.set(.failure(.unreachable)); done.signal()
        } as? HelperXPCProtocol
        guard let proxy else { return .failure(.unreachable) }
        proxy.handle(HelperWire.encode(HelperEnvelope(request: r, authorization: authorization))) { data in
            box.set(HelperWire.decode(HelperResponse.self, data).map { .success($0) } ?? .failure(.badReply))
            done.signal()
        }
        // On timeout the late reply is simply dropped.
        guard done.wait(timeout: .now() + deadline) == .success else { return .failure(.timeout) }
        return box.get() ?? .failure(.unreachable)
    }

    public func invalidate() {
        lock.lock()
        let c = connection
        connection = nil
        lock.unlock()
        c?.invalidate()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<HelperResponse, HelperClientError>?
        func set(_ v: Result<HelperResponse, HelperClientError>) { lock.lock(); if value == nil { value = v }; lock.unlock() }
        func get() -> Result<HelperResponse, HelperClientError>? { lock.lock(); defer { lock.unlock() }; return value }
    }
}

/// Stops calling a helper that keeps timing out: after three failures in a row, no calls for 30 s, and Settings
/// shows "Not responding". Busy and rate-limited replies are answers, not failures.
public struct HelperCallGate: Sendable {
    public static let failuresBeforeBackoff = 3
    public static let backoff: TimeInterval = 30
    private var failures = 0
    private var until: Date?

    public init() {}

    public var notResponding: Bool { failures >= Self.failuresBeforeBackoff }

    public mutating func allow(now: Date) -> Bool {
        guard let until else { return true }
        return now >= until
    }

    public mutating func record(success: Bool, now: Date) {
        if success { failures = 0; until = nil; return }
        failures += 1
        if failures >= Self.failuresBeforeBackoff { until = now.addingTimeInterval(Self.backoff) }
    }
}
