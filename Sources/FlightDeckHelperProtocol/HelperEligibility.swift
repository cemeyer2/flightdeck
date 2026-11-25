import Foundation
import Security

/// The parts of a code signature that decide whether the helper may be offered. Plain values so the rule is
/// testable against fixtures; `HelperEligibility.readSelf()` fills them from the running binary.
public struct SigningFacts: Sendable, Equatable {
    public var isAdHoc: Bool, teamID: String?, hardenedRuntime: Bool, getTaskAllow: Bool, developerIDLeaf: Bool
    public init(isAdHoc: Bool, teamID: String?, hardenedRuntime: Bool, getTaskAllow: Bool, developerIDLeaf: Bool) {
        self.isAdHoc = isAdHoc; self.teamID = teamID; self.hardenedRuntime = hardenedRuntime
        self.getTaskAllow = getTaskAllow; self.developerIDLeaf = developerIDLeaf
    }
}

public enum HelperBuildStatus: Sendable, Equatable { case eligible(teamID: String), needsSignedBuild, moveToApplications }

/// Developer ID builds only. An ad-hoc build has no team ID for launchd to pin the helper to, so the bundle's file
/// ownership would be its only protection, and /Applications is admin-writable. Both the app (before offering the
/// toggle) and the helper (on itself, at launch) run this check. There is deliberately no override.
public enum HelperEligibility {
    public static func evaluate(_ f: SigningFacts?, bundlePath: String) -> HelperBuildStatus {
        guard let f, !f.isAdHoc, let team = f.teamID, !team.isEmpty, f.hardenedRuntime, !f.getTaskAllow,
              f.developerIDLeaf else { return .needsSignedBuild }
        // Only a Developer ID copy is told to move: for any other build moving it wouldn't help.
        if isTranslocated(bundlePath) { return .moveToApplications }
        return .eligible(teamID: team)
    }

    /// Gatekeeper runs a quarantined app from Downloads or a disk image at a random read-only path, where
    /// SMAppService registration fails.
    public static func isTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    /// The listener's code-signing requirement for callers: FlightDeck itself, signed by the same team.
    public static func callerRequirement(teamID: String) -> String {
        "anchor apple generic and identifier \"\(HelperIDs.appBundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Signing facts of the running binary; nil if the signature can't be read (treated as ad-hoc).
    public static func readSelf() -> SigningFacts? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return facts(of: code)
    }

    /// Signing facts of any running code (the helper uses this on its XPC caller).
    public static func facts(of code: SecCode) -> SigningFacts? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }
        let codeFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        var leaf = false
        var req: SecRequirement?
        if SecRequirementCreateWithString("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" as CFString,
                                          [], &req) == errSecSuccess, let req {
            leaf = SecCodeCheckValidity(code, [], req) == errSecSuccess
        }
        return SigningFacts(isAdHoc: codeFlags & 0x0002 != 0,
                            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
                            hardenedRuntime: codeFlags & 0x10000 != 0,
                            getTaskAllow: entitlements?["com.apple.security.get-task-allow"] as? Bool ?? false,
                            developerIDLeaf: leaf)
    }
}
