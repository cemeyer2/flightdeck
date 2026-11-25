import Foundation
import Security
import FlightDeckHelperProtocol
import FlightDeckHelperCore

// FlightDeck's optional root helper: a launchd daemon started on demand by an XPC lookup of its Mach service, which
// exits after a minute with no connection. This file is only the XPC adapter; every rule (who may read what, PID
// re-checks, limits) is in FlightDeckHelperCore.HelperService. It deliberately does not link FlightDeckCore.

/// The helper sits at FlightDeck.app/Contents/Library/LaunchServices/<name>; the app is three folders up from there.
let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
let appURL = executable.deletingLastPathComponent()   // LaunchServices
    .deletingLastPathComponent()                      // Library
    .deletingLastPathComponent()                      // Contents
    .deletingLastPathComponent()                      // FlightDeck.app
let appBinary = appURL.appendingPathComponent("Contents/MacOS/FlightDeck").path

// The helper checks its own signature with the same rule the app uses. If this isn't a Developer ID build it keeps
// running (launchd would only respawn it) but refuses every request.
let build = HelperEligibility.evaluate(HelperEligibility.readSelf(), bundlePath: appURL.path)
let teamID: String? = { if case .eligible(let t) = build { return t }; return nil }()
let rightInPlace = teamID != nil && RightRegistrar.ensure(SystemAuthorizationAuthority())

let service = HelperService(authority: SystemAuthorizationAuthority(), registry: UnlockRegistry(),
                            runner: BoundedToolRunner(), processes: LibprocProcessReader(),
                            settings: FileHelperSettingsStore(),
                            eligible: { teamID != nil },
                            bundlePresent: { FileManager.default.fileExists(atPath: appBinary) },
                            rightInPlace: { rightInPlace })

/// One per connection: decodes the envelope and hands it to the service on the right queue.
final class Exported: NSObject, HelperXPCProtocol {
    let caller: HelperCaller
    init(_ caller: HelperCaller) { self.caller = caller }

    /// Tools that take seconds (lsof, sample, footprint…) run concurrently, so processRusage, status and lock never
    /// wait behind them. The quick kinds each get a serial queue.
    static let slow = DispatchQueue(label: "helper.slow", attributes: .concurrent)
    static let slowKinds: Set<String> = ["processDetails", "sampleStacks", "memoryFootprint", "listeningSockets",
                                          "internetSockets", "snapshotSizes", "deviceProfiles", "backgroundItems"]
    static let queuesLock = NSLock()
    static var queues: [String: DispatchQueue] = [:]
    static func queue(for kind: String) -> DispatchQueue {
        if slowKinds.contains(kind) { return slow }
        queuesLock.lock(); defer { queuesLock.unlock() }
        if let q = queues[kind] { return q }
        let q = DispatchQueue(label: "helper." + kind)
        queues[kind] = q
        return q
    }

    func handle(_ envelope: Data, reply: @escaping (Data) -> Void) {
        guard let e = HelperWire.decode(HelperEnvelope.self, envelope) else {
            reply(HelperWire.encode(HelperResponse.refused(HelperRefusal(code: .invalidParameter, message: "Unrecognised request."))))
            return
        }
        let caller = self.caller
        Self.queue(for: e.request.kind).async {
            reply(HelperWire.encode(service.handle(e, from: caller)))
        }
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    private let lock = NSLock()
    private var nextID: ConnectionID = 0
    private var open = 0
    private var generation = 0
    static let idleExit: TimeInterval = 60

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // The listener's code-signing requirement already pinned FlightDeck and the team; also insist on hardened
        // runtime and no get-task-allow, so code can't be injected into the caller. Identified by audit token only.
        guard let code = Self.code(of: c), let facts = HelperEligibility.facts(of: code),
              facts.hardenedRuntime, !facts.getTaskAllow else { return false }
        if let teamID {
            var req: SecRequirement?
            guard SecRequirementCreateWithString(HelperEligibility.callerRequirement(teamID: teamID) as CFString, [], &req) == errSecSuccess,
                  let req, SecCodeCheckValidity(code, [], req) == errSecSuccess else { return false }
        }
        lock.lock()
        nextID += 1
        let id = nextID
        open += 1
        generation += 1
        lock.unlock()
        c.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        c.exportedObject = Exported(HelperCaller(connection: id, uid: c.effectiveUserIdentifier))
        c.invalidationHandler = { [weak self] in
            service.connectionClosed(id)
            self?.closed()
        }
        c.resume()
        return true
    }

    private func closed() {
        lock.lock()
        open -= 1
        generation += 1
        let g = generation
        lock.unlock()
        scheduleIdleExit(g)
    }

    func scheduleIdleExit(_ g: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.idleExit) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let idle = self.open == 0 && self.generation == g
            self.lock.unlock()
            if idle { exit(0) }
        }
    }

    static func code(of c: NSXPCConnection) -> SecCode? {
        guard let v = c.value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        v.getValue(&token, size: MemoryLayout<audit_token_t>.size)
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess
        else { return nil }
        return code
    }
}

let delegate = Listener()
let listener = NSXPCListener(machServiceName: HelperIDs.machService)
if let teamID { listener.setConnectionCodeSigningRequirement(HelperEligibility.callerRequirement(teamID: teamID)) }
listener.delegate = delegate
listener.resume()
delegate.scheduleIdleExit(0)
dispatchMain()
