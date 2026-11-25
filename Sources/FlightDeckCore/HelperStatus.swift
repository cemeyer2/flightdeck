import Foundation
import FlightDeckHelperProtocol

/// SMAppService.Status, without importing ServiceManagement into Core.
public enum DaemonRegistration: Sendable { case notRegistered, enabled, requiresApproval, notFound }

/// Everything the Settings status line depends on, gathered by the app. Plain values so the precedence is testable.
public struct HelperStatusInputs: Sendable {
    public var demo: Bool, userEnabled: Bool, build: HelperBuildStatus, registration: DaemonRegistration
    public var registrationError: String?, hello: HelloOutcome?, mismatchSurvivedRelaunch: Bool
    public var unlocked: Bool, notResponding: Bool, registrationRefused: Bool
    public init(demo: Bool = false, userEnabled: Bool = false, build: HelperBuildStatus = .needsSignedBuild,
                registration: DaemonRegistration = .notRegistered, registrationError: String? = nil,
                hello: HelloOutcome? = nil, mismatchSurvivedRelaunch: Bool = false, unlocked: Bool = false,
                notResponding: Bool = false, registrationRefused: Bool = false) {
        self.demo = demo; self.userEnabled = userEnabled; self.build = build; self.registration = registration
        self.registrationError = registrationError; self.hello = hello
        self.mismatchSurvivedRelaunch = mismatchSurvivedRelaunch; self.unlocked = unlocked
        self.notResponding = notResponding; self.registrationRefused = registrationRefused
    }
}

public enum HelperFix: Equatable, Sendable { case openLoginItems, unlock, lock, reinstall }

/// The one status Settings shows for the helper, with at most one fix.
public enum HelperStatus: Equatable, Sendable {
    case off, moveToApplications, needsSignedBuild, waitingForApproval, locked, unlocked, outOfDate, notResponding, notSupported
    case failed(String)

    /// First match wins. A build that can't use the helper says so even if the toggle was left on.
    public static func resolve(_ i: HelperStatusInputs) -> HelperStatus {
        if i.demo { return .off }
        if i.build == .needsSignedBuild { return .needsSignedBuild }
        if i.build == .moveToApplications { return .moveToApplications }
        if !i.userEnabled { return .off }
        if i.registrationRefused { return .notSupported }
        if let e = i.registrationError { return .failed(e) }
        if i.registration == .requiresApproval { return .waitingForApproval }
        // The toggle says on but nothing is registered (a failed install, or removed elsewhere): it is off.
        if i.registration == .notRegistered || i.registration == .notFound { return .off }
        if i.hello == .refused(.bundleMissing) { return .failed("the helper couldn't find FlightDeck") }
        if i.hello == .ok(rightInPlace: false) { return .failed("couldn't set up the administrator check") }
        // Any other refusal of hello (notably the helper's own signature check failing where the app's passed) can't
        // be fixed by unlocking, so it must not read as Locked with an Unlock button that does nothing.
        if case .refused(let code)? = i.hello {
            return .failed(code == .notEligible ? "the helper didn't accept this copy's signature" : "the helper refused to connect (\(code.rawValue))")
        }
        if i.hello == .mismatch { return i.mismatchSurvivedRelaunch ? .outOfDate : .notResponding }
        if i.notResponding || i.hello == .unreachable { return .notResponding }
        return i.unlocked ? .unlocked : .locked
    }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .moveToApplications: return "Move FlightDeck to Applications first"
        case .needsSignedBuild: return "Needs a signed build"
        case .waitingForApproval: return "Waiting for approval in Login Items"
        case .locked: return "On · Locked"
        case .unlocked: return "On · Unlocked"
        case .outOfDate: return "Out of date"
        case .notResponding: return "Not responding"
        case .notSupported: return "Not supported on this macOS"
        case .failed(let reason): return "Failed (\(reason))"
        }
    }

    public var explanation: String? {
        switch self {
        case .needsSignedBuild:
            return "The helper runs as root, so FlightDeck only installs it from a build signed with a Developer ID. Everything else works as usual."
        case .moveToApplications:
            return "macOS runs apps opened from Downloads or a disk image from a temporary read-only copy, where the helper can't be installed."
        case .waitingForApproval: return "macOS asks you to allow FlightDeck's helper in System Settings › Login Items."
        case .outOfDate: return "The installed helper is from another version of FlightDeck."
        case .notResponding: return "FlightDeck shows its own readings until the helper answers again."
        case .off, .locked, .unlocked, .notSupported, .failed: return nil
        }
    }

    public var fix: HelperFix? {
        switch self {
        case .waitingForApproval: return .openLoginItems
        case .locked: return .unlock
        case .unlocked: return .lock
        case .outOfDate: return .reinstall
        default: return nil
        }
    }

    public var toggleEnabled: Bool {
        switch self {
        case .needsSignedBuild, .moveToApplications: return false
        default: return true
        }
    }
}
