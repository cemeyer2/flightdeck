import Foundation
import FlightDeckHelperProtocol

public struct HelperCaller: Sendable {
    public var connection: ConnectionID
    public var uid: uid_t
    public init(connection: ConnectionID, uid: uid_t) { self.connection = connection; self.uid = uid }
}

/// Every rule the helper enforces, as plain code over injectable seams (authority, registry, tool runner, process
/// reader, settings), so it is unit-tested without root or XPC. The XPC listener in FlightDeckHelper is a thin
/// adapter that calls `handle` and `connectionClosed`. Thread-safe: state is under a lock, which is never held while
/// a tool runs, so a slow `sample` can't hold up the per-tick rusage call.
public final class HelperService {
    private let authority: AuthorizationAuthority
    private let registry: UnlockRegistry
    private let runner: ToolRunning
    private let processes: ProcessReading
    private let settings: HelperSettingsStoring
    private let eligible: () -> Bool
    private let bundlePresent: () -> Bool
    private let rightInPlace: () -> Bool
    private let clock: () -> Date

    private let lock = NSLock()
    private var greeted: Set<ConnectionID> = []
    private var inFlight: Set<String> = []
    private var lastStart: [String: Date] = [:]

    public init(authority: AuthorizationAuthority, registry: UnlockRegistry, runner: ToolRunning,
                processes: ProcessReading, settings: HelperSettingsStoring,
                eligible: @escaping () -> Bool, bundlePresent: @escaping () -> Bool, rightInPlace: @escaping () -> Bool,
                clock: @escaping () -> Date = Date.init) {
        self.authority = authority; self.registry = registry; self.runner = runner; self.processes = processes
        self.settings = settings; self.eligible = eligible; self.bundlePresent = bundlePresent
        self.rightInPlace = rightInPlace; self.clock = clock
    }

    public func handle(_ e: HelperEnvelope, from c: HelperCaller) -> HelperResponse {
        guard eligible() else {
            return refuse(.notEligible, "This copy of FlightDeck isn't signed with a Developer ID, so the helper won't run for it.")
        }
        guard bundlePresent() else { return refuse(.bundleMissing, "The helper couldn't find FlightDeck.") }

        if case .hello(let v) = e.request {
            let ok = v == HelperIDs.protocolVersion
            withLock { if ok { greeted.insert(c.connection) } else { greeted.remove(c.connection) } }
            guard ok else {
                return refuse(.versionMismatch, "FlightDeck and its helper are different versions (\(v) and \(HelperIDs.protocolVersion)).")
            }
            return .hello(HelperHello(version: HelperIDs.protocolVersion, rightInPlace: rightInPlace(), eligible: true))
        }
        guard withLock({ greeted.contains(c.connection) }) else { return refuse(.helloRequired, "Say hello first.") }
        if let r = HelperValidation.validate(e.request) { return .refused(r) }

        // The authd check runs outside the lock; the registry is only touched under it.
        var verified = withLock { registry.cachedVerification(connection: c.connection) }
        if !verified, let form = e.authorization {
            verified = authority.verify(externalForm: form, right: HelperIDs.rightName)
            withLock {
                if verified { registry.recordVerification(connection: c.connection) }
                else { registry.verificationFailed(connection: c.connection) }
            }
        }
        let access = withLock { registry.access(connection: c.connection, uid: c.uid, verified: verified) }

        switch e.request.tier {
        case .control:
            return control(e.request, c, access)
        case .counters:
            guard access != .none else { return notAuthorized() }
        case .contents:
            switch access {
            case .full: break
            case .counters:
                return refuse(.notHolder, "Process details are only given to the FlightDeck window that was unlocked.")
            case .none: return notAuthorized()
            }
        }

        let kind = e.request.kind
        let busy: HelperRefusal.Code? = withLock {
            if inFlight.contains(kind) { return .busy }
            let now = clock()
            if HelperLimits.rateLimitedKinds.contains(kind), let last = lastStart[kind],
               now.timeIntervalSince(last) < HelperLimits.minInterval { return .rateLimited }
            inFlight.insert(kind)
            lastStart[kind] = now
            return nil
        }
        switch busy {
        case .busy?: return refuse(.busy, "The helper is already answering that kind of request.")
        case .rateLimited?: return refuse(.rateLimited, "Asked too often; try again in a couple of seconds.")
        default: break
        }
        defer { _ = withLock { inFlight.remove(kind) } }
        return data(e.request)
    }

    public func connectionClosed(_ c: ConnectionID) {
        withLock {
            greeted.remove(c)
            registry.connectionClosed(c)
        }
    }

    // MARK: Requests

    private func control(_ r: HelperRequest, _ c: HelperCaller, _ access: Access) -> HelperResponse {
        switch r {
        case .status:
            let alive = withLock { registry.holderAlive(uid: c.uid) }
            return .status(HelperServiceStatus(unlocked: access == .full, holderAlive: alive, agentContents: settings.agentContents))
        case .lock:
            withLock { registry.lock(connection: c.connection) }
            return .ok
        case .removeRightAndSettings:
            // Needs no unlock: it only takes access away.
            _ = authority.removeRule(HelperIDs.rightName)
            settings.removeAll()
            return .ok
        default:
            return refuse(.invalidParameter, "Not a control request.")
        }
    }

    private func data(_ r: HelperRequest) -> HelperResponse {
        switch r {
        case .setAgentContents(let on):
            do { try settings.setAgentContents(on) } catch {
                return refuse(.toolFailed, "The helper couldn't save the agent setting: \(error.localizedDescription)")
            }
            return .ok
        case .processRusage(let ids):
            // A recycled identity is left out silently; the rest of the batch is still answered.
            var out: [HelperRusageEntry] = []
            for id in ids {
                guard processes.identity(of: id.pid) == id, let ru = processes.rusage(of: id.pid),
                      processes.identity(of: id.pid) == id else { continue }
                out.append(HelperRusageEntry(id: id, rusage: ru))
            }
            return .rusage(out)
        case .processDetails(let id, let parts):
            guard processes.identity(of: id.pid) == id else { return processChanged() }
            let contents = processes.contents(of: id.pid, parts: parts)
            guard processes.identity(of: id.pid) == id else { return processChanged() }
            return .contents(contents)
        case .sampleStacks(let id, let seconds):
            return pausing(id) { .sample(pid: id.pid, seconds: seconds) }
        case .memoryFootprint(let id):
            return pausing(id) { .footprint(pid: id.pid) }
        case .listeningSockets:
            return listening()
        case .internetSockets:
            return text(.lsofInternet)
        case .snapshotSizes:
            return parsed(.tmutilSnapshots, "tmutil", HelperParsers.snapshotSizes) { .snapshotSizes($0) }
        case .deviceProfiles:
            return parsed(.profilesDevice, "profiles", HelperParsers.deviceProfiles) { .profiles($0) }
        case .backgroundItems:
            return parsed(.sfltoolDumpbtm, "sfltool", HelperParsers.backgroundItems) { .backgroundItems($0) }
        case .hello, .status, .lock, .removeRightAndSettings:
            return refuse(.invalidParameter, "Not a data request.")
        }
    }

    /// sample and footprint suspend the target while they read it: refused for critical processes, and the identity
    /// is checked before and after so a recycled PID's output is never returned.
    private func pausing(_ id: HelperProcessID, _ tool: () -> HelperTool) -> HelperResponse {
        guard processes.identity(of: id.pid) == id, let name = processes.name(of: id.pid) else { return processChanged() }
        if HelperValidation.isCritical(pid: id.pid, name: name) { return .refused(HelperValidation.criticalRefusal(name)) }
        let result = runner.run(tool())
        guard processes.identity(of: id.pid) == id else { return processChanged() }
        return toolResponse(result) { .toolText($0) }
    }

    /// netstat as root first (it lists every socket with its process); lsof as root if netstat gave nothing. The
    /// first line says which, so the app picks the matching parser; netstat's UDP table follows a "#udp" line, since
    /// the app parses each table separately.
    private func listening() -> HelperResponse {
        let tcp = runner.run(.netstatTCP), udp = runner.run(.netstatUDP)
        if case .output(let t) = tcp, case .output(let u) = udp,
           !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !u.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .toolText("#netstat\n" + t + "\n#udp\n" + u)
        }
        return toolResponse(runner.run(.lsofListening)) { .toolText("#lsof\n" + $0) }
    }

    private func parsed<T>(_ tool: HelperTool, _ name: String, _ parse: (String) -> T?,
                           _ wrap: (T) -> HelperResponse) -> HelperResponse {
        toolResponse(runner.run(tool)) { out in
            guard let v = parse(out) else { return refuse(.toolFailed, "couldn't read \(name) output") }
            return wrap(v)
        }
    }

    private func text(_ tool: HelperTool) -> HelperResponse {
        toolResponse(runner.run(tool)) { .toolText($0) }
    }

    private func toolResponse(_ r: ToolResult, _ ok: (String) -> HelperResponse) -> HelperResponse {
        switch r {
        case .output(let s): return ok(s)
        case .tooLarge: return refuse(.outputTooLarge, "The tool's output was too large to return.")
        case .failed: return refuse(.toolFailed, "The tool failed.")
        case .timedOut: return refuse(.toolFailed, "The tool took too long.")
        }
    }

    private func processChanged() -> HelperResponse {
        refuse(.processChanged, "That process has exited and its PID was reused, so nothing was read.")
    }

    private func notAuthorized() -> HelperResponse {
        refuse(.notAuthorized, "An administrator needs to unlock FlightDeck first.")
    }

    private func refuse(_ code: HelperRefusal.Code, _ message: String) -> HelperResponse {
        .refused(HelperRefusal(code: code, message: message))
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
