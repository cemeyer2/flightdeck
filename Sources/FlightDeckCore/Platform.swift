import Foundation

/// Where macOS keeps its own programs. Rules never act on anything here, and the process catalog only vouches for an
/// Apple-named program found here (or one with a valid Apple signature). `/usr/local/` is deliberately left out:
/// Homebrew and the user can write there.
public enum Platform {
    /// Cryptexes hold Safari and other parts of macOS that update separately from the system volume.
    public static let prefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/bin/", "/sbin/", "/Library/Apple/",
                                  "/System/Volumes/Preboot/Cryptexes/"]

    /// The user-writable Data volume, reachable through "/System/" (/System/Volumes/Data/Users/…), so it is excluded.
    static let writableUnderSystem = "/System/Volumes/Data/"

    public static func isPlatformPath(_ path: String) -> Bool {
        !path.hasPrefix(writableUnderSystem) && prefixes.contains { path.hasPrefix($0) }
    }
}
