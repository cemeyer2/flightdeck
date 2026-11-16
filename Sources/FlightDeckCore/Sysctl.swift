import Foundation
import Darwin

// Thin typed wrappers over sysctlbyname(3), used throughout FlightDeckCore for static hardware facts
// (hw.*, machdep.cpu.*) and kernel state (kern.boottime, vm.*). Every reader returns nil when the name
// doesn't exist on this Mac or the call fails, so callers can show "unavailable" instead of a made-up 0.
/// Namespace for reading sysctl values by name. Stateless and safe to call from any thread.
public enum Sysctl {
    /// Reads an integer sysctl. Accepts both 32-bit (e.g. `hw.ncpu`) and 64-bit (e.g. `hw.memsize`) values:
    /// an 8-byte buffer is offered and the kernel reports how many bytes it actually wrote in `size`.
    /// Returns nil if the name is unknown or the value is wider than 8 bytes (sysctl fails with ENOMEM).
    public static func int(_ name: String) -> Int? {
        var v: Int64 = 0; var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &v, &size, nil, 0) == 0 {
            // A 4-byte value only fills the low half of `v` (little-endian), so truncate and sign-extend it
            // as an Int32 rather than reading whatever the zeroed upper half implies.
            if size == 4 { return Int(Int32(truncatingIfNeeded: v)) }
            return Int(v)
        }
        return nil
    }
    /// Reads a NUL-terminated string sysctl (e.g. `machdep.cpu.brand_string`, `hw.model`). The first call
    /// with a nil buffer asks the kernel for the required size; nil if missing or empty.
    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    /// Reads a `struct timeval` sysctl (seconds + microseconds since 1970) as a Date. Used for
    /// `kern.boottime` by SystemInfo to compute uptime.
    public static func timeval(_ name: String) -> Date? {
        var tv = Darwin.timeval(); var size = MemoryLayout<Darwin.timeval>.size
        guard sysctlbyname(name, &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6)
    }
}
