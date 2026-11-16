import Foundation
import IOKit

// Read every 5 minutes by Sampler (Snapshot.drives) and shown in the storage views; Analyzer can raise findings from
// `healthy`/`warnings`. Values are decoded straight from the 512-byte NVMe "SMART / Health Information" log page (02h).
/// NVMe SMART / health log of internal SSDs via Apple's NVMeSMARTLib plugin (no root needed).
public struct DriveHealth: Codable, Sendable, Hashable, Identifiable {
    public var id: String { serial ?? model }
    public var model: String
    public var serial: String?
    public var criticalWarning: UInt8      // NVMe bit field; 0 = none
    public var temperature: Double         // °C
    public var availableSpare: Int         // %
    public var spareThreshold: Int         // %
    public var percentUsed: Int            // wear estimate, can exceed 100
    /// Host bytes read / written over the drive's life. Double because the NVMe counters are 128-bit.
    public var bytesRead: Double
    public var bytesWritten: Double
    // Lifetime counters from the log page; they persist across reboots and only reset if the drive is replaced.
    public var powerOnHours: UInt64
    public var powerCycles: UInt64
    public var unsafeShutdowns: UInt64
    public var mediaErrors: UInt64
    public var errorLogEntries: UInt64

    /// Overall verdict: no critical-warning bits, no media errors, spare at or above threshold, and under 90% wear.
    public var healthy: Bool { criticalWarning == 0 && mediaErrors == 0 && availableSpare >= spareThreshold && percentUsed < 90 }
    /// Human-readable reasons behind `healthy` being false; the bit meanings are from the NVMe spec's Critical Warning byte.
    public var warnings: [String] {
        var w: [String] = []
        if criticalWarning & 0x01 != 0 || availableSpare < spareThreshold { w.append("spare capacity below threshold") }
        if criticalWarning & 0x02 != 0 { w.append("temperature out of range") }
        if criticalWarning & 0x04 != 0 { w.append("reliability degraded") }
        if criticalWarning & 0x08 != 0 { w.append("drive is read-only") }
        if criticalWarning & 0x10 != 0 { w.append("volatile memory backup failed") }
        if mediaErrors > 0 { w.append("\(mediaErrors) media errors") }
        if percentUsed >= 90 { w.append("\(percentUsed)% of rated endurance used") }
        return w
    }
}

/// Mirrors the C IONVMeSMARTInterface vtable (IOKit's NVMeSMARTLib plugin): the IUnknown "guts" (reserved,
/// QueryInterface, AddRef, Release), then version/revision and SMARTReadData. Field order and types must match the C
/// header exactly; after the two UInt16s the next function pointer is 8-byte aligned in both languages, so the implicit
/// 4 bytes of padding agree. Entries after SMARTReadData are omitted since only the struct's prefix is ever read.
private struct SMARTVTable {
    var reserved: UnsafeMutableRawPointer?
    var QueryInterface: @convention(c) (UnsafeMutableRawPointer?, REFIID, UnsafeMutablePointer<LPVOID?>?) -> HRESULT
    var AddRef: @convention(c) (UnsafeMutableRawPointer?) -> ULONG
    var Release: @convention(c) (UnsafeMutableRawPointer?) -> ULONG
    var version: UInt16
    var revision: UInt16
    var SMARTReadData: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
}

/// Enumerates NVMe drives and reads their SMART log through the NVMeSMARTLib CFPlugIn. No root needed; drives the
/// plugin can't open are skipped, and the result is [] on Macs without NVMe storage (e.g. SATA-based Intel Macs).
public enum DriveHealthReader {
    // kIONVMeSMARTUserClientTypeID, kIONVMeSMARTInterfaceID, kIOCFPlugInInterfaceID
    static let typeID = CFUUIDGetConstantUUIDWithBytes(nil, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    static let interfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    static let plugInID = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)

    /// Blocking IOKit calls; Sampler calls it from the sampling queue only every 5 minutes.
    public static func read() -> [DriveHealth] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONVMeBlockStorageDevice"), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [DriveHealth] = []
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            guard (IORegistryEntryCreateCFProperty(svc, "NVMe SMART Capable" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) == true,
                  let log = smartLog(svc) else { continue }
            let chars = IORegistryEntryCreateCFProperty(svc, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            // Log page fields are little-endian. Offsets: 0 critical warning, 1-2 composite temperature (kelvin), 3 available
            // spare %, 4 spare threshold %, 5 percentage used, 32/48 data units read/written (128-bit), 112 power cycles,
            // 128 power-on hours, 144 unsafe shutdowns, 160 media errors, 176 error-log entries (the 128-bit counters are read as
            // their low 64 bits except where u128 is used).
            func u64(_ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(log[o + $1]) << (8 * UInt64($1)) } }
            func u128(_ o: Int) -> Double { Double(u64(o)) + Double(u64(o + 8)) * 18_446_744_073_709_551_616.0 }
            let kelvin = Int(log[1]) | Int(log[2]) << 8
            out.append(DriveHealth(
                model: (chars?["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "NVMe SSD",
                serial: (chars?["Serial Number"] as? String)?.trimmingCharacters(in: .whitespaces),
                criticalWarning: log[0], temperature: Double(kelvin) - 273.15,
                availableSpare: Int(log[3]), spareThreshold: Int(log[4]), percentUsed: Int(log[5]),
                bytesRead: u128(32) * 512_000, bytesWritten: u128(48) * 512_000,   // data units are 1000 × 512 bytes
                powerOnHours: u64(128), powerCycles: u64(112), unsafeShutdowns: u64(144),
                mediaErrors: u64(160), errorLogEntries: u64(176)))
        }
        return out
    }

    /// The CFPlugIn dance: create the plugin for the service, QueryInterface for the SMART interface, call SMARTReadData
    /// into a 512-byte buffer, then Release the interface and destroy the plugin. nil on any failure.
    static func smartLog(_ svc: io_service_t) -> [UInt8]? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(svc, typeID, plugInID, &plugin, &score) == KERN_SUCCESS, let plugin, let vt = plugin.pointee else { return nil }
        defer { IODestroyPlugInInterface(plugin) }
        var iface: LPVOID?
        guard vt.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(interfaceID), &iface) == S_OK, let iface else { return nil }
        let smart = iface.assumingMemoryBound(to: UnsafeMutablePointer<SMARTVTable>.self).pointee.pointee
        defer { _ = smart.Release(iface) }
        var log = [UInt8](repeating: 0, count: 512)
        let r = log.withUnsafeMutableBytes { smart.SMARTReadData(iface, $0.baseAddress) }
        return r == kIOReturnSuccess ? log : nil
    }
}
