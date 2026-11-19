import Foundation
import CoreLocation
// Location Services permission, which macOS requires before it gives an app Wi-Fi SSIDs and BSSIDs (they can reveal
// where the Mac is). FlightDeck never uses the location itself. The permission is only requested when the user presses
// the button on the Wi-Fi page; reading the status here never prompts.

public enum WiFiPermission {
    public enum Status: String, Sendable {
        case granted, denied, restricted, notDetermined = "not asked yet", servicesOff = "Location Services off"
    }

    /// Current status without prompting.
    public static func status() -> Status {
        guard CLLocationManager.locationServicesEnabled() else { return .servicesOff }
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Plain-English explanation shown when names are hidden.
    public static func explanation(_ s: Status) -> String {
        let base = "macOS hides Wi-Fi network names (SSIDs) and access point addresses (BSSIDs) from apps without Location Services permission, because they can reveal where this Mac is. FlightDeck never reads your location."
        switch s {
        case .granted: return "Location Services permission is granted, so network names and BSSIDs are visible."
        case .notDetermined: return base + " Press Allow to be asked."
        case .denied: return base + " Permission was declined; turn FlightDeck on in System Settings › Privacy & Security › Location Services."
        case .restricted: return base + " Permission is restricted on this Mac (for example by a management profile)."
        case .servicesOff: return base + " Location Services is turned off in System Settings › Privacy & Security."
        }
    }
}
