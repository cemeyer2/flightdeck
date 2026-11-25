import Foundation
import FlightDeckHelperProtocol

/// What the helper adds right now, as the UI and MCP report it ("helper": "off" | "locked" | "unlocked").
public enum HelperAccessState: String, Codable, Sendable { case off, locked, unlocked }

public extension ProcessIdentity {
    init(_ h: HelperProcessID) { self.init(pid: h.pid, startTime: h.startTime) }
    var helperID: HelperProcessID { HelperProcessID(pid: pid, startTime: startTime) }
}

public enum HelloOutcome: Equatable, Sendable { case ok(rightInPlace: Bool), mismatch, unreachable, refused(HelperRefusal.Code) }

/// One per process (the app, or a standalone --mcp / --snapshot). Holds the client, the hello result, the last status
/// and the back-off gate. Thread-safe. The app's session passes its authorization's external form with every request;
/// a standalone session has none and is served counters only while the app holds an unlock.
public final class HelperSession: @unchecked Sendable {
    /// The app's Settings toggle (UserDefaults).
    public static let enabledKey = "helperEnabled"
    /// The per-sample rusage call's hard deadline; past it the tick uses app-only values.
    public static let perTickDeadline: TimeInterval = 0.1
    /// hello and status may take longer (the helper may be launching).
    public static let controlDeadline: TimeInterval = 2
    /// How stale a standalone session's view of the app's unlock may get.
    static let standaloneStatusAge: TimeInterval = 5

    private let client: HelperClient
    private let authorization: () -> Data?
    private let clock: () -> Date
    private let standaloneMode: Bool
    private let mutex = NSLock()
    private var hello: HelloOutcome?
    private var status: HelperServiceStatus?
    private var statusTime: Date?
    private var gate = HelperCallGate()

    public convenience init(client: HelperClient, authorization: @escaping () -> Data?, clock: @escaping () -> Date = Date.init) {
        self.init(client: client, authorization: authorization, clock: clock, standalone: false)
    }

    init(client: HelperClient, authorization: @escaping () -> Data?, clock: @escaping () -> Date, standalone: Bool) {
        self.client = client; self.authorization = authorization; self.clock = clock; standaloneMode = standalone
    }

    /// off until hello succeeds. The app's session is unlocked only while it holds an authorization and the helper
    /// agrees; a standalone session is "unlocked" (for counters) while the app's unlock is alive.
    public var state: HelperAccessState {
        mutex.lock(); defer { mutex.unlock() }
        guard case .ok? = hello else { return .off }
        if standaloneMode { return status?.holderAlive == true ? .unlocked : .locked }
        guard authorization() != nil, status?.unlocked == true else { return .locked }
        return .unlocked
    }

    /// "Let AI agents read other processes' details", from the last status; false when unreachable or standalone.
    public var agentContents: Bool {
        mutex.lock(); defer { mutex.unlock() }
        return !standaloneMode && status?.agentContents == true
    }

    public var lastHello: HelloOutcome? { mutex.lock(); defer { mutex.unlock() }; return hello }
    public var notResponding: Bool { mutex.lock(); defer { mutex.unlock() }; return gate.notResponding }

    /// Sends hello. On a version mismatch the connection is dropped (an old helper may still be running after an
    /// update; launchd starts the new one after its idle exit). Never call on the main thread.
    @discardableResult
    public func connect(deadline: TimeInterval = controlDeadline) -> HelloOutcome {
        let outcome: HelloOutcome
        switch raw(.hello(version: HelperIDs.protocolVersion), deadline: deadline) {
        case .success(.hello(let h)) where h.version == HelperIDs.protocolVersion: outcome = .ok(rightInPlace: h.rightInPlace)
        case .success(.hello): outcome = .mismatch
        case .failure(.refused(let r)) where r.code == .versionMismatch: outcome = .mismatch
        case .failure(.refused(let r)): outcome = .refused(r.code)
        case .success, .failure: outcome = .unreachable
        }
        if outcome == .mismatch { client.invalidate() }
        mutex.lock()
        hello = outcome
        if case .ok = outcome {} else { status = nil }
        mutex.unlock()
        return outcome
    }

    public func refreshStatus(deadline: TimeInterval = controlDeadline) {
        let r = request(.status, deadline: deadline)
        mutex.lock(); defer { mutex.unlock() }
        if case .success(.status(let s)) = r { status = s } else { status = nil }
        statusTime = clock()
    }

    /// Refreshes the status when it is older than `maxAge`. A standalone session has no unlock of its own, so this is
    /// how it notices the app unlocking, locking or quitting.
    public func refreshIfStale(maxAge: TimeInterval, deadline: TimeInterval = controlDeadline) {
        mutex.lock()
        let stale = statusTime.map { clock().timeIntervalSince($0) >= maxAge } ?? true
        mutex.unlock()
        if stale { refreshStatus(deadline: deadline) }
    }

    /// Passes through the back-off gate, connecting first if needed. A helper that restarted (idle exit) asks for
    /// hello again; that is answered once, transparently.
    public func request(_ r: HelperRequest, deadline: TimeInterval) -> Result<HelperResponse, HelperClientError> {
        if lastHello == nil || lastHello == .unreachable { connect(deadline: max(deadline, Self.perTickDeadline)) }
        guard case .ok? = lastHello else { return .failure(.unreachable) }
        let first = raw(r, deadline: deadline)
        if case .failure(.refused(let x)) = first, x.code == .helloRequired, case .ok = connect() {
            return raw(r, deadline: deadline)
        }
        return first
    }

    private func raw(_ r: HelperRequest, deadline: TimeInterval) -> Result<HelperResponse, HelperClientError> {
        mutex.lock()
        let allowed = gate.allow(now: clock())
        mutex.unlock()
        guard allowed else { return .failure(.unreachable) }
        let result = client.send(r, authorization: standaloneMode ? nil : authorization(), deadline: deadline)
        let failed: Bool
        switch result {
        case .failure(.timeout), .failure(.unreachable): failed = true
        default: failed = false
        }
        mutex.lock(); gate.record(success: !failed, now: clock()); mutex.unlock()
        if case .success(.refused(let x)) = result { return .failure(.refused(x)) }
        return result
    }

    /// Counters for the identities the app couldn't read, in batches of at most HelperLimits.maxBatch, all within one
    /// per-tick deadline. nil = no helper values this tick (locked, off, slow or backing off).
    public func rusage(for ids: [ProcessIdentity]) -> [ProcessIdentity: HelperRusage]? {
        guard !ids.isEmpty else { return nil }
        let end = clock().addingTimeInterval(Self.perTickDeadline)
        if standaloneMode { refreshIfStale(maxAge: Self.standaloneStatusAge, deadline: Self.perTickDeadline) }
        guard state == .unlocked else { return nil }
        var out: [ProcessIdentity: HelperRusage] = [:]
        var answered = false
        var reconnected = false
        var start = 0
        while start < ids.count {
            let remaining = end.timeIntervalSince(clock())
            guard remaining > 0 else { break }
            let batch = ids[start..<min(start + HelperLimits.maxBatch, ids.count)].map(\.helperID)
            var result = raw(.processRusage(ids: batch), deadline: remaining)
            // A helper that relaunched (idle exit, update) asks for hello again: answer it once, within this tick.
            if case .failure(.refused(let x)) = result, x.code == .helloRequired, !reconnected {
                reconnected = true
                let left = end.timeIntervalSince(clock())
                if left > 0, case .ok = connect(deadline: left) {
                    result = raw(.processRusage(ids: batch), deadline: max(end.timeIntervalSince(clock()), 0.001))
                }
            }
            start += HelperLimits.maxBatch
            guard case .success(.rusage(let entries)) = result else { continue }
            answered = true
            for e in entries { out[ProcessIdentity(e.id)] = e.rusage }
        }
        return answered ? out : nil
    }

    /// Ends this connection's unlock in the helper. The caller then frees its authorization.
    public func lock() {
        _ = raw(.lock, deadline: Self.controlDeadline)
        mutex.lock(); status = nil; mutex.unlock()
    }

    /// Drops the XPC connection (which also ends any unlock record the helper holds for it). The next request
    /// connects again.
    public func disconnect() {
        client.invalidate()
        mutex.lock(); hello = nil; status = nil; statusTime = nil; mutex.unlock()
    }

    /// Standalone --mcp/--snapshot: a session with no authorization, only when the app's toggle is on, the build is
    /// eligible and demo mode is off (`defaults.bool(forKey: "demo")`, the key the app's Demo.isEnabled reads). nil
    /// otherwise. Nothing is sent until first use.
    public static func standalone(build: HelperBuildStatus, defaults: UserDefaults = .standard) -> HelperSession? {
        guard defaults.bool(forKey: enabledKey), !defaults.bool(forKey: "demo"), case .eligible(let team) = build else { return nil }
        return HelperSession(client: XPCHelperClient(teamID: team), authorization: { nil }, clock: Date.init, standalone: true)
    }
}
