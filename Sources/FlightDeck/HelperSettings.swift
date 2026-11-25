import SwiftUI
import Security
import ServiceManagement
import FlightDeckCore
import FlightDeckHelperProtocol

// The optional root helper, app side: registration with SMAppService, the administrator unlock, the Settings section
// and the small "View all processes…" / Lock affordances used by other pages. Everything here is inert on ad-hoc
// builds (every build until there is a Developer ID certificate) and in demo mode: nothing is registered, started,
// unlocked or queried, and no dialog is ever shown at launch.

/// The administrator authorization, in memory only: never in user defaults, files or the keychain. Its external form
/// travels only over the helper's XPC connection.
final class HelperUnlock: @unchecked Sendable {
    private let lock = NSLock()
    private var ref: AuthorizationRef?
    private var form: Data?

    /// Shows macOS's administrator dialog. Blocking, so call it off the main thread, and only from a button action.
    func unlock() -> Bool {
        var r: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &r) == errAuthorizationSuccess, let r else { return false }
        let granted = HelperIDs.rightName.withCString { name -> Bool in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { p -> Bool in
                var rights = AuthorizationRights(count: 1, items: p)
                return AuthorizationCopyRights(r, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil) == errAuthorizationSuccess
            }
        }
        var ext = AuthorizationExternalForm()
        guard granted, AuthorizationMakeExternalForm(r, &ext) == errAuthorizationSuccess else {
            AuthorizationFree(r, [.destroyRights])
            return false
        }
        let data = withUnsafeBytes(of: &ext.bytes) { Data($0) }
        lock.lock()
        let old = ref
        ref = r; form = data
        lock.unlock()
        if let old { AuthorizationFree(old, [.destroyRights]) }
        return true
    }

    var externalForm: Data? { lock.lock(); defer { lock.unlock() }; return form }

    /// Frees the authorization and its credential; the next unlock prompts again.
    func relock() {
        lock.lock()
        let old = ref
        ref = nil; form = nil
        lock.unlock()
        if let old { AuthorizationFree(old, [.destroyRights]) }
    }
}

/// The helper's state for Settings and the pages that offer "View all processes…". One per app.
@MainActor
final class HelperModel: ObservableObject {
    static let shared = HelperModel()

    @Published private(set) var status: HelperStatus = .off
    @Published private(set) var agentContents = false
    /// An unregister() failure after turning the helper off (the status itself then reads Off).
    @Published private(set) var unregisterError: String?
    /// Why the last change to the agent setting didn't take (the toggle shows the stored value either way).
    @Published private(set) var agentContentsError: String?
    @Published private(set) var busy = false

    /// The session for the current state: nil unless the toggle is on, the build is eligible, the daemon is
    /// registered and demo mode is off.
    private(set) var session: HelperSession? {
        didSet {
            // An error from the old session's change says nothing about the new one.
            if oldValue !== session { agentContentsError = nil }
            Self.box.set(session); onSessionChange?(session)
        }
    }
    /// The Engine hands the session to the sampler on its queue.
    var onSessionChange: ((HelperSession?) -> Void)?

    let build: HelperBuildStatus
    private let unlockHolder = HelperUnlock()
    private var hello: HelloOutcome?
    private var registrationError: String?
    private var registrationRefused = false
    private var mismatchSurvivedRelaunch = false
    private var mismatchRetry: Task<Void, Never>?

    private var daemon: SMAppService { SMAppService.daemon(plistName: HelperIDs.plistName) }
    private var userEnabled: Bool { UserDefaults.standard.bool(forKey: HelperSession.enabledKey) }

    init() {
        build = Demo.isEnabled ? .needsSignedBuild : HelperEligibility.evaluate(HelperEligibility.readSelf(), bundlePath: Bundle.main.bundlePath)
        cleanUpIfIneligible()
        refresh()
    }

    /// The current session from any thread (readers run on background tasks).
    nonisolated static func currentSession() -> HelperSession? { box.get() }
    private nonisolated static let box = SessionBox()
    private final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var s: HelperSession?
        func set(_ v: HelperSession?) { lock.lock(); s = v; lock.unlock() }
        func get() -> HelperSession? { lock.lock(); defer { lock.unlock() }; return s }
    }

    var isOn: Bool { userEnabled && !Demo.isEnabled }

    private func registration() -> DaemonRegistration {
        switch daemon.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    /// An ad-hoc build dropped over a Developer ID copy that had the helper on: unregister it, silently. (This build
    /// can't reach a Developer ID helper to remove its right; the right grants nothing on its own.)
    private func cleanUpIfIneligible() {
        guard !Demo.isEnabled, build == .needsSignedBuild else { return }
        let reg = registration()
        if reg == .enabled || reg == .requiresApproval { try? daemon.unregister() }
    }

    /// Re-reads SMAppService's status (nothing is stored) and rebuilds the status line. Never registers, never prompts.
    func refresh() {
        guard !Demo.isEnabled, case .eligible(let team) = build else {
            session = nil
            status = HelperStatus.resolve(HelperStatusInputs(demo: Demo.isEnabled, build: build))
            return
        }
        let reg = userEnabled ? registration() : .notRegistered
        if userEnabled && reg == .enabled {
            if session == nil {
                let holder = unlockHolder
                session = HelperSession(client: XPCHelperClient(teamID: team), authorization: { holder.externalForm })
            }
            if hello == nil, let s = session { connect(s) }
        } else if session != nil {
            drop()
        }
        // On, but nothing registered and no install error to show (removed elsewhere, or a failed install before a
        // relaunch): turn the toggle off so the toggle, the status and standalone --mcp agree.
        if userEnabled && (reg == .notRegistered || reg == .notFound) && registrationError == nil && !registrationRefused && !busy {
            UserDefaults.standard.set(false, forKey: HelperSession.enabledKey)
        }
        let inputs = HelperStatusInputs(demo: false, userEnabled: userEnabled, build: build, registration: reg,
                                        registrationError: registrationError, hello: userEnabled && reg == .enabled ? hello : nil,
                                        mismatchSurvivedRelaunch: mismatchSurvivedRelaunch,
                                        unlocked: session?.state == .unlocked, notResponding: session?.notResponding ?? false,
                                        registrationRefused: registrationRefused)
        status = HelperStatus.resolve(inputs)
        agentContents = session?.agentContents ?? false
    }

    /// Hello off the main thread. A version mismatch is retried once after the old helper's idle exit.
    private func connect(_ s: HelperSession) {
        Task.detached(priority: .utility) {
            let outcome = s.connect()
            if case .ok = outcome { s.refreshStatus() }
            await MainActor.run {
                self.hello = outcome
                if outcome == .mismatch { self.scheduleMismatchRetry(s) }
                self.refresh()
            }
        }
    }

    private func scheduleMismatchRetry(_ s: HelperSession) {
        guard mismatchRetry == nil, !mismatchSurvivedRelaunch else { return }
        mismatchRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(65))   // past the helper's 60 s idle exit
            let again = await Task.detached(priority: .utility) { s.disconnect(); return s.connect() }.value
            guard let self else { return }
            self.hello = again
            if again == .mismatch { self.mismatchSurvivedRelaunch = true }
            self.mismatchRetry = nil
            self.refresh()
        }
    }

    private func drop() {
        let s = session
        session = nil
        hello = nil
        unlockHolder.relock()
        if let s { Task.detached(priority: .utility) { s.disconnect() } }
    }

    // MARK: Actions (from buttons only)

    func setEnabled(_ on: Bool) {
        guard !Demo.isEnabled, case .eligible = build else { return }
        registrationError = nil; registrationRefused = false; unregisterError = nil
        mismatchSurvivedRelaunch = false
        if on {
            UserDefaults.standard.set(true, forKey: HelperSession.enabledKey)
            register()
            refresh()
        } else {
            UserDefaults.standard.set(false, forKey: HelperSession.enabledKey)
            let s = session
            let holder = unlockHolder
            session = nil; hello = nil
            busy = true
            Task.detached(priority: .userInitiated) {
                // Ask the helper to remove its right and settings first; unreachable is fine (the right alone grants nothing).
                if let s {
                    _ = s.request(.removeRightAndSettings, deadline: HelperSession.controlDeadline)
                    s.lock()
                    s.disconnect()
                }
                holder.relock()
                await MainActor.run { self.unregister() }
            }
        }
    }

    private func register() {
        do {
            try daemon.register()
        } catch {
            // Waiting for approval in Login Items is reported as an error by some macOS versions; it isn't one.
            if daemon.status == .requiresApproval { return }
            let code = (error as NSError).code
            if code == kSMErrorServiceUnavailable { registrationRefused = true }
            else { registrationError = error.localizedDescription }
            try? daemon.unregister()   // never leave a half-registered daemon behind
        }
    }

    private func unregister() {
        daemon.unregister { error in
            Task { @MainActor in
                self.busy = false
                if let error, self.daemon.status != .notRegistered { self.unregisterError = error.localizedDescription }
                self.refresh()
            }
        }
    }

    func reinstall() {
        guard !Demo.isEnabled, case .eligible = build else { return }
        drop()
        mismatchSurvivedRelaunch = false
        try? daemon.unregister()
        register()
        refresh()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// Prompts for an administrator, only after hello confirmed the right is in place. Cancel or a wrong password
    /// changes nothing and shows nothing.
    func unlock() {
        guard let s = session, hello == .ok(rightInPlace: true), !busy else { return }
        busy = true
        let holder = unlockHolder
        Task.detached(priority: .userInitiated) {
            if holder.unlock() { s.refreshStatus() }
            await MainActor.run { self.busy = false; self.refresh() }
        }
    }

    func lock() {
        guard let s = session else { return }
        agentContentsError = nil
        let holder = unlockHolder
        Task.detached(priority: .userInitiated) {
            s.lock()
            holder.relock()
            s.disconnect()   // ends the helper's record even if the lock request didn't arrive
            await MainActor.run { self.hello = nil; self.refresh() }
        }
    }

    func setAgentContents(_ on: Bool) {
        guard let s = session, s.state == .unlocked else { return }
        Task.detached(priority: .userInitiated) {
            var error: String?
            if case .failure(let e) = s.request(.setAgentContents(on), deadline: HelperSession.controlDeadline) {
                error = e.description
            }
            s.refreshStatus()
            await MainActor.run { [error] in self.agentContentsError = error; self.refresh() }
        }
    }
}

/// Settings › Integrations: the toggle, one status line with its fix, what the helper unlocks and the agent setting.
struct HelperSettingsSection: View {
    @ObservedObject private var model = HelperModel.shared

    var body: some View {
        Section("System-wide details") {
            Toggle("Allow FlightDeck to read system-wide details (installs a helper that runs as root)", isOn: Binding(get: { model.isOn }, set: { if $0 != model.isOn { model.setEnabled($0) } }))
                .disabled(!model.status.toggleEnabled || Demo.isEnabled || model.busy)
            HStack {
                Text(model.status.title).font(.callout.bold())
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                switch model.status.fix {
                case .openLoginItems?: Button("Open Login Items") { model.openLoginItems() }
                case .unlock?: Button("Unlock…") { model.unlock() }.disabled(model.busy)
                case .lock?: Button("Lock") { model.lock() }
                case .reinstall?: Button("Reinstall") { model.reinstall() }
                case nil: EmptyView()
                }
            }
            if let x = model.status.explanation { note(x) }
            if let e = model.unregisterError { note("Couldn't remove the helper: \(e)").foregroundStyle(.orange) }
            if model.status != .needsSignedBuild && model.status != .moveToApplications && !Demo.isEnabled {
                note("""
                Once an administrator unlocks it, FlightDeck also shows: other users' and system processes' CPU, memory, disk, \
                energy and wake-ups (and the Users page's totals); every process's listening ports and connections; local \
                snapshot sizes; configuration profiles installed for the whole Mac; Login Items background items; and, on \
                request, other processes' arguments, open files, call stacks and memory breakdown.
                """)
                note("Read-only: it can't change anything.")
                note("Root data needs an administrator's password each time FlightDeck starts.")
                Toggle("Let AI agents read other processes' details (arguments, environment, open files, stacks)",
                       isOn: Binding(get: { model.agentContents }, set: { model.setAgentContents($0) }))
                    .disabled(model.status != .unlocked)
                if let e = model.agentContentsError { note("Couldn't change the agent setting: \(e)").foregroundStyle(.orange) }
            }
            if Demo.isEnabled { note("Not available in demo mode.") }
        }
        .onAppear { model.refresh() }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Where a page shows only the user's own processes: "View all processes…" while locked, Lock while unlocked, and a
/// pointer to Settings while off. Nothing at all on builds that can't use the helper.
struct HelperAccessButton: View {
    @ObservedObject private var model = HelperModel.shared

    var body: some View {
        switch model.status {
        case .locked: Button("View all processes…") { model.unlock() }.disabled(model.busy).controlSize(.small)
        case .unlocked: Button("Lock") { model.lock() }.controlSize(.small).help("Stop showing root data until an administrator unlocks again")
        default: EmptyView()
        }
    }

    /// Appended to "your own processes only" notes while the helper is off on a build that could use it.
    @MainActor static var offNote: String {
        HelperModel.shared.status == .off && HelperModel.shared.build != .needsSignedBuild && !Demo.isEnabled
            ? " — turn on the helper in Settings to see all" : ""
    }
}

/// Inspector: another user's or a root process's contents, live while unlocked (never saved, copied into Copy Summary
/// or recorded), and one-off stack and memory samples that briefly pause the process.
struct HelperInspectorPanel: View {
    @ObservedObject private var model = HelperModel.shared
    let sample: ProcessSample
    @State private var contents: HelperProcessContents?
    @State private var result: String?
    @State private var working = false
    @State private var lastFetch = Date.distantPast
    /// The process the panel currently shows. Replies are checked against it after they arrive, since `sample` in an
    /// async continuation is the view value captured when the request was sent.
    @State private var shownID: HelperProcessID?

    var body: some View {
        if sample.uid != getuid() && model.build != .needsSignedBuild && !Demo.isEnabled {
            Panel(title: "System-wide details", trailing: model.status == .unlocked ? "via helper · not saved" : model.status.title) {
                if model.status == .unlocked {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                        GridRow { Text("Arguments").foregroundStyle(.secondary); Text(contents?.args?.joined(separator: " ") ?? "—") }
                        GridRow { Text("Working directory").foregroundStyle(.secondary); Text(contents?.cwd ?? "—") }
                        GridRow { Text("Environment").foregroundStyle(.secondary); Text(contents?.env.map { "\($0.count) variables" } ?? "—") }
                        GridRow { Text("Open files").foregroundStyle(.secondary); Text(contents?.files.map { "\($0.count)" } ?? "—") }
                        GridRow { Text("Sockets").foregroundStyle(.secondary); Text(contents?.sockets?.prefix(20).joined(separator: "\n") ?? "—") }
                    }.font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Sample stacks (pauses the process briefly)") { run(.sampleStacks(id: sample.identity.helperID, seconds: 2)) }
                        Button("Memory breakdown (pauses the process briefly)") { run(.memoryFootprint(id: sample.identity.helperID)) }
                        if working { ProgressView().controlSize(.small) }
                    }.disabled(working)
                    if let result {
                        ScrollView(.horizontal) {
                            Text(result).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).fixedSize()
                        }.frame(minHeight: 200)
                    }
                } else if model.status == .locked {
                    HStack { Text("An administrator can unlock other users' details."); HelperAccessButton() }
                } else {
                    Text("Other users' details need the helper\(HelperAccessButton.offNote.isEmpty ? "." : HelperAccessButton.offNote + ".")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            // On selection and every 10 s at most (the helper rate-limits this request across every caller).
            // Keyed on the full identity: a reused PID is another process. A new selection starts empty, so a
            // rate-limited or busy reply never leaves the previous process's details under this one.
            .task(id: "\(sample.identity.pid)-\(sample.identity.startTime)-\(model.status == .unlocked)") {
                shownID = sample.identity.helperID; contents = nil; result = nil
                await fetch()
            }
            .onChange(of: sample.cpuTime) { if Date().timeIntervalSince(lastFetch) > 10 { Task { await fetch() } } }
        }
    }

    private func fetch() async {
        guard model.status == .unlocked, let s = HelperModel.currentSession() else { contents = nil; return }
        lastFetch = Date()
        let id = sample.identity.helperID
        let r = await Task.detached(priority: .utility) {
            s.request(.processDetails(id: id, parts: [.args, .env, .cwd, .files, .sockets]), deadline: 10)
        }.value
        // The selection moved on while the helper answered: this reply belongs to another process.
        guard id == shownID else { return }
        // Rate-limited or busy: keep what is shown (it is this process's, or nothing).
        if case .success(.contents(let c)) = r { contents = c }
        else if case .failure(.refused(let x)) = r, x.code == .processChanged { contents = nil }
    }

    private func run(_ request: HelperRequest) {
        guard let s = HelperModel.currentSession() else { return }
        working = true
        let id = sample.identity.helperID
        Task {
            let r = await Task.detached(priority: .userInitiated) { s.request(request, deadline: 30) }.value
            working = false
            guard id == shownID else { return }
            switch r {
            case .success(.toolText(let t)): result = t
            case .failure(let e): result = e.description
            default: result = "The helper's reply wasn't recognised."
            }
        }
    }
}
