import AppKit

// Feeds ProcessSample.notResponding. Sampler (Snapshot.swift) calls check() at most every 2 seconds because it
// walks every GUI app. Analyzer turns a true value into a "not responding" finding, which Engine may follow with
// an automatic stack capture.
/// Asks the window server which GUI apps are not responding (the "beachball" state Activity Monitor shows),
/// via SkyLight symbols resolved at runtime. If they're missing, everything reports nil (unknown), not false.
/// There is no public API for this: the window server decides an app is unresponsive when it stops draining its
/// event queue, and only SkyLight (private) exposes that verdict. Resolving with dlsym means a future macOS that
/// removes or renames a symbol degrades to "unknown" instead of crashing at launch with a missing-symbol error.
public enum HangDetector {
    /// `CGSMainConnectionID()`: this process's window-server connection, needed by the query below.
    typealias ConnFn = @convention(c) () -> Int32
    /// `CGSEventIsAppUnresponsive(connection, psn)`: true while the app is beachballing.
    typealias UnrespFn = @convention(c) (Int32, UnsafePointer<ProcessSerialNumber>) -> Bool
    /// `GetProcessForPID` (deprecated Carbon API): the window server identifies apps by ProcessSerialNumber, not PID.
    typealias PSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    /// Resolved once, lazily (Swift static lets are initialised thread-safely). nil if any symbol is missing.
    /// The dlopen handles are intentionally never closed: the functions are used for the life of the app.
    static let fns: (ConnFn, UnrespFn, PSNFn)? = {
        let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        let as_ = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
        // CGS* symbols live in SkyLight on current macOS (re-exported by CoreGraphics on older ones);
        // GetProcessForPID lives under ApplicationServices. Try both handles for each name.
        func sym(_ n: String) -> UnsafeMutableRawPointer? { dlsym(sl, n) ?? dlsym(as_, n) }
        guard let c = sym("CGSMainConnectionID"), let u = sym("CGSEventIsAppUnresponsive"), let g = sym("GetProcessForPID") else { return nil }
        return (unsafeBitCast(c, to: ConnFn.self), unsafeBitCast(u, to: UnrespFn.self), unsafeBitCast(g, to: PSNFn.self))
    }()

    /// Whether hang detection works on this macOS; when false the UI shows hang state as unknown.
    public static var isAvailable: Bool { fns != nil }

    /// PIDs of regular (Dock) apps, each mapped to whether it is unresponsive. Empty if unavailable.
    /// Only `.regular` apps are asked: accessories and background agents have no window-server event queue that
    /// can be judged, so they are left absent (unknown) rather than reported as responsive.
    /// Runs on the Sampler's serial queue; NSWorkspace.runningApplications is safe to read off the main thread.
    public static func check() -> [Int32: Bool] {
        guard let (conn, unresp, psnOf) = fns else { return [:] }
        let cid = conn()
        var out: [Int32: Bool] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            var psn = ProcessSerialNumber()
            // The app may have quit since the list was taken; skip it rather than guess.
            guard psnOf(app.processIdentifier, &psn) == noErr else { continue }
            out[app.processIdentifier] = unresp(cid, &psn)
        }
        return out
    }
}
