import Foundation
import Darwin

public enum Sysctl {
    public static func int(_ name: String) -> Int? {
        var v: Int64 = 0; var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &v, &size, nil, 0) == 0 {
            if size == 4 { return Int(Int32(truncatingIfNeeded: v)) }
            return Int(v)
        }
        return nil
    }
    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    public static func timeval(_ name: String) -> Date? {
        var tv = Darwin.timeval(); var size = MemoryLayout<Darwin.timeval>.size
        guard sysctlbyname(name, &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6)
    }
}
