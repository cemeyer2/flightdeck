import Foundation

// Shared by FlightDeck and its optional root helper (FlightDeckHelper). This target holds only wire types,
// validators, parsers and the build check, so the root binary carries none of FlightDeckCore.
/// Names both sides must agree on. Used verbatim in the launchd plist, the bundle layout and the right database.
public enum HelperIDs {
    /// Mach service name, launchd label and the helper binary's file name.
    public static let machService = "app.flightdeck.Flightdeck.helper"
    public static let plistName = "app.flightdeck.Flightdeck.helper.plist"
    public static let appBundleID = "app.flightdeck.Flightdeck"
    /// The authorization right that needs an administrator's name and password.
    public static let rightName = "app.flightdeck.Flightdeck.helper.read-all"
    /// Compared in `hello`. Bump on any change to the wire types; the app build number doesn't matter.
    public static let protocolVersion = 1
}
