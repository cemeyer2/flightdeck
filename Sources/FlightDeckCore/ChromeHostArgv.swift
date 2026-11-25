import Foundation
// Chrome tabs: is this launch of the app binary Chrome starting its native-messaging host? Chrome runs the manifest's
// `path` with the calling extension's origin as the first argument ("chrome-extension://<id>/"), and a manifest path
// can't carry a flag, so the origin itself is the signal. Only an exact allowed origin enters host mode; anything else
// that looks like an extension origin exits quietly rather than opening the GUI. `CLI.handle()` asks this first,
// before anything that prints.

public enum ChromeHostArgv {
    public enum Mode: Equatable {
        /// Run as the host. `origin` is nil for the hidden `--chrome-host` flag (tests and manual runs).
        case host(origin: String?)
        /// An extension origin that isn't ours: print nothing and exit non-zero.
        case rejected
        case notHost
    }

    public static func mode(_ argv: [String], allowed: [String] = ChromeTabsConstants.allowedOrigins) -> Mode {
        guard argv.count > 1 else { return .notHost }
        let a = argv[1]
        if allowed.contains(a) { return .host(origin: a) }
        if a == "--chrome-host" { return .host(origin: nil) }
        if a.hasPrefix("chrome-extension://") { return .rejected }
        return .notHost
    }

    /// True only when Chrome launched us with an allowed origin.
    public static func isHostInvocation(_ argv: [String]) -> Bool {
        if case .host(let o?) = mode(argv) { return !o.isEmpty }
        return false
    }
}
