import Foundation
import IOKit

public struct FanReading: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var rpm: Double
    public var minRPM: Double?
    public var maxRPM: Double?
    public var targetRPM: Double?
    public var fraction: Double? { maxRPM.map { max(0, min(rpm / max($0, 1), 1)) } }
}

/// Minimal read-only AppleSMC client (fans). Keys that don't exist or decode to an unknown type are skipped.
public final class SMC: @unchecked Sendable {
    // Mirrors SMCKeyData_t from the SMC user client. Explicit padding keeps Swift from packing fields into
    // tail padding, which would shift every following field relative to the C layout.
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

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ input: inout KeyData) -> Bool {
        var out = KeyData(); var size = MemoryLayout<KeyData>.size
        guard IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.size, &out, &size) == KERN_SUCCESS, out.result == 0 else { return false }
        input = out; return true
    }

    /// Raw bytes and 4-char type of a key.
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

    public func fans() -> [FanReading] {
        guard let n = number("FNum"), n > 0 else { return [] }
        return (0..<min(Int(n), 8)).compactMap { i in
            guard let rpm = number("F\(i)Ac") else { return nil }
            return FanReading(index: i, rpm: max(rpm, 0), minRPM: number("F\(i)Mn"), maxRPM: number("F\(i)Mx"), targetRPM: number("F\(i)Tg"))
        }
    }
}
