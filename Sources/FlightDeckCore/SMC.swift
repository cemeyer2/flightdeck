import Foundation
import IOKit

// Read-only access to the System Management Controller through the AppleSMC IOKit user client, used for fan speeds in
// every PowerSample. There is no public fan API; reading SMC keys needs no root or entitlement.
/// One fan. All speeds are RPM; min/max/target are nil when the SMC doesn't publish that key.
public struct FanReading: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var rpm: Double
    public var minRPM: Double?
    public var maxRPM: Double?
    public var targetRPM: Double?
    /// Current speed as a 0...1 fraction of the fan's maximum (for gauges); nil without a max.
    public var fraction: Double? { maxRPM.map { max(0, min(rpm / max($0, 1), 1)) } }
}

/// Minimal read-only AppleSMC client (fans). Keys that don't exist or decode to an unknown type are skipped.
/// A single shared connection, opened once. `read` is serialised by `lock` because the user client is a single
/// request/response channel and SMC.shared may be used from several queues. If AppleSMC can't be opened, `conn` stays 0
/// and every read returns nil.
public final class SMC: @unchecked Sendable {
    // Mirrors SMCKeyData_t from the SMC user client. Explicit padding keeps Swift from packing fields into
    // tail padding, which would shift every following field relative to the C layout.
    // C layout (80 bytes): key u32 | vers (6 bytes) | pLimitData (16, 4-aligned) | keyInfo (12 incl. 3 pad bytes) |
    // result u8, status u8, data8 u8 | data32 u32 | bytes[32]. The tuple of four UInt64 stands in for the 32-byte array.
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, attributes: UInt8 = 0, pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    struct KeyData {
        var key: UInt32 = 0; var version = Version(); var pLimit = PLimit(); var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0; var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private var conn: io_connect_t = 0
    private let lock = NSLock()
    public static let shared = SMC()

    private init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        if IOServiceOpen(svc, mach_task_self_, 0, &conn) != KERN_SUCCESS { conn = 0 }
    }

    /// Packs a four-character SMC key such as "F0Ac" into the big-endian UInt32 the SMC expects.
    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    /// One request through user-client selector 2 (the SMC's single "handle event" entry point). `data8` in the input
    /// selects the operation. A non-zero `result` is the SMC's own error code (e.g. key not found).
    private func call(_ input: inout KeyData) -> Bool {
        var out = KeyData(); var size = MemoryLayout<KeyData>.size
        guard IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.size, &out, &size) == KERN_SUCCESS, out.result == 0 else { return false }
        input = out; return true
    }

    /// Raw bytes and 4-char type of a key.
    /// Two round trips: first ask for the key's size and type (op 9, get key info), then read that many bytes (op 5).
    /// The type is also a four-char code, turned back into a string by its big-endian bytes.
    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard conn != 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        var info = KeyData(); info.key = Self.fourCC(key); info.data8 = 9          // get key info
        guard call(&info) else { return nil }
        let size = info.keyInfo.dataSize, type = info.keyInfo.dataType
        var r = KeyData(); r.key = Self.fourCC(key); r.keyInfo.dataSize = size; r.data8 = 5   // read key
        guard call(&r) else { return nil }
        let t = String(bytes: withUnsafeBytes(of: type.bigEndian) { Array($0) }, encoding: .ascii) ?? "?"
        return (t, withUnsafeBytes(of: r.bytes) { Array($0.prefix(Int(min(size, 32)))) })
    }

    /// Decodes the numeric SMC types used by fan keys: "flt " (32-bit float in host byte order, used on Apple silicon),
    /// "ui8 ", big-endian "ui16", and "fpe2" (unsigned 14.2 fixed point, Intel fan keys). Other types return nil.
    func number(_ key: String) -> Double? {
        guard let (t, b) = read(key) else { return nil }
        switch t {
        case "flt " where b.count >= 4: return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "ui8 " where b.count >= 1: return Double(b[0])
        case "ui16" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "fpe2" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4   // Intel fans
        default: return nil
        }
    }

    /// Fans from FNum and the per-fan F<i>Ac/Mn/Mx/Tg keys (actual, minimum, maximum, target). Empty on fanless Macs or
    /// when the SMC is unreadable. At most 8 fans are queried so a garbage FNum can't trigger a long loop.
    public func fans() -> [FanReading] {
        guard let n = number("FNum"), n > 0 else { return [] }
        return (0..<min(Int(n), 8)).compactMap { i in
            guard let rpm = number("F\(i)Ac") else { return nil }
            return FanReading(index: i, rpm: max(rpm, 0), minRPM: number("F\(i)Mn"), maxRPM: number("F\(i)Mx"), targetRPM: number("F\(i)Tg"))
        }
    }
}
