import Foundation
// Chrome tabs: the fixed names and limits shared by the native-messaging host (the app binary launched by Chrome), the
// socket listener in the app and the tests. The extension's source is in Extensions/Chrome; its ID is pinned by the
// public "key" in its manifest, so it is the same on every Mac (it is not a secret, see ChromePeerAuth).

public enum ChromeTabsConstants {
    /// The native-messaging host name the extension connects to, and the host manifest's file name (plus ".json").
    public static let hostName = "app.flightdeck.chrome"
    /// Bumped when a message's shape changes incompatibly; a `hello` with another value is ignored.
    public static let protocolVersion = 1
    /// The unpacked extension's ID (from the manifest "key"). A Chrome Web Store item's ID is appended here later; once
    /// its public key replaces the manifest's, both are the same.
    public static let extensionIDs = ["eaafcbkolhbacjkgamicbppfahipoenj"]
    /// What Chrome passes as the host's first argument, and the host manifest's `allowed_origins`.
    public static var allowedOrigins: [String] { extensionIDs.map { "chrome-extension://\($0)/" } }
    public static let extensionName = "FlightDeck Tabs"

    /// Largest frame either reader accepts, checked on the 4-byte length before anything is allocated.
    public static let maxFrameBytes = 2 * 1024 * 1024
    public static let maxTabs = 1000, maxFramesPerTab = 200
    /// String limits, in UTF-8 bytes.
    public static let maxURLBytes = 8192, maxOriginBytes = 2048, maxTitleBytes = 2048
}
