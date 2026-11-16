import Foundation
import IOKit

public struct DiskDevice: Codable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var readBps: Double
    public var writeBps: Double
    public var totalRead: UInt64
    public var totalWritten: UInt64
}

public struct VolumeInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var capacity: UInt64
    public var available: UInt64
    public var fileSystem: String
    public var isInternal: Bool
    public var used: UInt64 { capacity > available ? capacity - available : 0 }
}

public struct DiskSample: Codable, Sendable {
    public var readBps: Measured<Double>
    public var writeBps: Measured<Double>
    public var devices: [DiskDevice]
    public var volumes: [VolumeInfo]
}

public final class DiskSampler {
    private var previous: [String: (UInt64, UInt64)] = [:]
    private var lastTime: Date?
    private var volumeCache: [VolumeInfo] = []
    private var volumeAge = 0
    public init() {}

    private func readDrivers() -> [String: (UInt64, UInt64)] {
        var result: [String: (UInt64, UInt64)] = [:]
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iter) }
        var idx = 0
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service); idx += 1 }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["Statistics"] as? [String: Any] else { continue }
            let r = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            var name = "disk\(idx)"
            var child: io_registry_entry_t = 0
            if IORegistryEntryGetChildEntry(service, kIOServicePlane, &child) == KERN_SUCCESS {
                if let bsd = IORegistryEntryCreateCFProperty(child, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String { name = bsd }
                IOObjectRelease(child)
            }
            result[name] = (r, w)
        }
        return result
    }

    public static func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable ?? true,
                  let cap = v.volumeTotalCapacity, cap > 0 else { return nil }
            let avail = v.volumeAvailableCapacityForImportantUsage.map { UInt64($0) } ?? UInt64(v.volumeAvailableCapacity ?? 0)
            return VolumeInfo(name: v.volumeName ?? url.lastPathComponent, path: url.path, capacity: UInt64(cap),
                              available: avail, fileSystem: v.volumeLocalizedFormatDescription ?? "",
                              isInternal: v.volumeIsInternal ?? false)
        }
    }

    public func sample() -> DiskSample {
        let now = Date()
        let cur = readDrivers()
        if volumeAge % 10 == 0 { volumeCache = Self.volumes() }
        volumeAge += 1
        defer { previous = cur; lastTime = now }
        guard let lastTime, !previous.isEmpty else {
            return DiskSample(readBps: .unavailable("warming up"), writeBps: .unavailable("warming up"),
                              devices: cur.map { DiskDevice(name: $0.key, readBps: 0, writeBps: 0, totalRead: $0.value.0, totalWritten: $0.value.1) },
                              volumes: volumeCache)
        }
        let dt = max(now.timeIntervalSince(lastTime), 0.001)
        var devices: [DiskDevice] = []
        var tr = 0.0, tw = 0.0
        for (name, v) in cur.sorted(by: { $0.key < $1.key }) {
            let p = previous[name] ?? v
            // a device's counters can reset (e.g. a disk image remounted): that is 0, not a 50 PB/s spike
            let r = v.0 >= p.0 ? Double(v.0 - p.0) / dt : 0, w = v.1 >= p.1 ? Double(v.1 - p.1) / dt : 0
            tr += r; tw += w
            devices.append(DiskDevice(name: name, readBps: r, writeBps: w, totalRead: v.0, totalWritten: v.1))
        }
        return DiskSample(readBps: .value(tr), writeBps: .value(tw), devices: devices, volumes: volumeCache)
    }
}
