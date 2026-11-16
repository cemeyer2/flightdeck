import AppKit

/// Asks the window server which GUI apps are not responding (the "beachball" state Activity Monitor shows),
/// via SkyLight symbols resolved at runtime. If they're missing, everything reports nil (unknown), not false.
public enum HangDetector {
    typealias ConnFn = @convention(c) () -> Int32
    typealias UnrespFn = @convention(c) (Int32, UnsafePointer<ProcessSerialNumber>) -> Bool
    typealias PSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    nonisolated(unsafe) static let fns: (ConnFn, UnrespFn, PSNFn)? = {
        let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        let as_ = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
        func sym(_ n: String) -> UnsafeMutableRawPointer? { dlsym(sl, n) ?? dlsym(as_, n) }
        guard let c = sym("CGSMainConnectionID"), let u = sym("CGSEventIsAppUnresponsive"), let g = sym("GetProcessForPID") else { return nil }
        return (unsafeBitCast(c, to: ConnFn.self), unsafeBitCast(u, to: UnrespFn.self), unsafeBitCast(g, to: PSNFn.self))
    }()

    public static var isAvailable: Bool { fns != nil }

    /// PIDs of regular (Dock) apps, each mapped to whether it is unresponsive. Empty if unavailable.
    public static func check() -> [Int32: Bool] {
        guard let (conn, unresp, psnOf) = fns else { return [:] }
        let cid = conn()
        var out: [Int32: Bool] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            var psn = ProcessSerialNumber()
            guard psnOf(app.processIdentifier, &psn) == noErr else { continue }
            out[app.processIdentifier] = unresp(cid, &psn)
        }
        return out
    }
}
