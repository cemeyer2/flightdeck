import Foundation

// Disk Space › "What's using my disk": the startup disk's APFS container split into the parts macOS's Storage settings
// lumps together as "System Data". Parsers for `diskutil apfs list -plist`, `diskutil info -plist /` and
// `tmutil listlocalsnapshots /` live here so they can be tested with captured output; the I/O is in
// StorageBreakdownRead.swift. Nothing here needs root.

/// One APFS volume and the space it uses inside its container (`CapacityInUse`, bytes).
public struct APFSVolumeUsage: Sendable, Hashable, Identifiable {
    public var id: String { device }
    public var name: String
    /// BSD device, e.g. "disk3s5".
    public var device: String
    /// APFS roles, e.g. ["Data"], ["System"], ["Preboot"]. Empty for a plain user volume.
    public var roles: [String]
    public var used: UInt64
    public init(name: String, device: String, roles: [String], used: UInt64) {
        self.name = name; self.device = device; self.roles = roles; self.used = used
    }
}

/// An APFS container: one pool of space shared by all its volumes.
public struct APFSContainerUsage: Sendable, Hashable {
    /// e.g. "disk3".
    public var reference: String
    /// `CapacityCeiling`: the container's size in bytes.
    public var capacity: UInt64
    /// `CapacityFree`: space no volume has claimed (doesn't include purgeable space).
    public var free: UInt64
    public var volumes: [APFSVolumeUsage]
    public init(reference: String, capacity: UInt64, free: UInt64, volumes: [APFSVolumeUsage]) {
        self.reference = reference; self.capacity = capacity; self.free = free; self.volumes = volumes
    }
}

/// A local snapshot of the startup volume group, from `tmutil listlocalsnapshots /`.
public struct LocalSnapshot: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case timeMachine, osUpdate, other }
    public var id: String { name }
    public var name: String
    public var kind: Kind
    /// Parsed from the Time Machine snapshot name (local time); nil for the other kinds.
    public var date: Date?
}

public enum StorageParse {
    static func plist(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
    /// Plist integers arrive as NSNumber; negative or missing values are treated as absent rather than 0.
    static func uint(_ any: Any?) -> UInt64? {
        guard let n = any as? NSNumber, n.int64Value >= 0 else { return nil }
        return n.uint64Value
    }

    /// Every container in `diskutil apfs list -plist`. Containers without a size are skipped; a volume without
    /// `CapacityInUse` is skipped too, rather than shown as using 0 bytes.
    public static func apfsContainers(_ data: Data) -> [APFSContainerUsage]? {
        guard let root = plist(data), let list = root["Containers"] as? [[String: Any]] else { return nil }
        return list.compactMap { c in
            guard let ref = c["ContainerReference"] as? String, let cap = uint(c["CapacityCeiling"]),
                  let free = uint(c["CapacityFree"]) else { return nil }
            let vols = (c["Volumes"] as? [[String: Any]] ?? []).compactMap { v -> APFSVolumeUsage? in
                guard let dev = v["DeviceIdentifier"] as? String, let used = uint(v["CapacityInUse"]) else { return nil }
                return APFSVolumeUsage(name: v["Name"] as? String ?? dev, device: dev, roles: v["Roles"] as? [String] ?? [], used: used)
            }
            return APFSContainerUsage(reference: ref, capacity: cap, free: free, volumes: vols)
        }
    }

    /// From `diskutil info -plist /`: which container the startup volume is in, and the volume's name.
    public static func startupContainer(_ data: Data) -> (container: String, volumeName: String?)? {
        guard let d = plist(data), let ref = d["APFSContainerReference"] as? String else { return nil }
        return (ref, d["VolumeName"] as? String)
    }

    /// `tmutil listlocalsnapshots /` prints a header line, then one snapshot name per line. Returns nil when the output
    /// doesn't look like that list (tmutil failed or printed an error), [] when there are no snapshots.
    public static func localSnapshots(_ out: String) -> [LocalSnapshot]? {
        let lines = out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let header = lines.first, header.hasPrefix("Snapshots for") else { return nil }
        return lines.dropFirst().map { name in
            if name.hasPrefix("com.apple.TimeMachine.") {
                return LocalSnapshot(name: name, kind: .timeMachine, date: timeMachineDate(name))
            }
            return LocalSnapshot(name: name, kind: name.hasPrefix("com.apple.os.update-") ? .osUpdate : .other, date: nil)
        }
    }

    /// "com.apple.TimeMachine.2026-11-17-072255.local" → that local date and time.
    static func timeMachineDate(_ name: String) -> Date? {
        let stem = name.replacingOccurrences(of: "com.apple.TimeMachine.", with: "").replacingOccurrences(of: ".local", with: "")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: stem)
    }

    /// Space macOS counts as available but has to purge first (caches it manages, local snapshots, iCloud files it can
    /// re-download): "available for important usage" minus plain "available". Nil when the important figure isn't
    /// reported (it's 0 off the startup volume), so purgeable reads "unknown" instead of 0.
    public static func purgeable(important: Int64?, available: Int64?) -> UInt64? {
        guard let i = important, i > 0, let a = available, a >= 0 else { return nil }
        return i > a ? UInt64(i - a) : 0
    }
}

/// One part of the startup-disk bar.
public struct StorageSegment: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case data, purgeable, system, preboot, recovery, vm, update, otherVolumes, overhead, free
    }
    public var id: Kind { kind }
    public var kind: Kind
    public var title: String
    public var bytes: UInt64
    /// What this part is, in plain English.
    public var explanation: String
}

/// The startup disk's container, split for the stacked bar.
public struct StorageBreakdown: Sendable {
    public var container: APFSContainerUsage
    public var volumeName: String?
    /// Nil = unknown (macOS didn't report "available for important usage").
    public var purgeable: UInt64?
    /// Nil when tmutil couldn't list them; `snapshotNote` then says why.
    public var snapshots: [LocalSnapshot]?
    public var snapshotNote: String?
    public init(container: APFSContainerUsage, volumeName: String?, purgeable: UInt64?, snapshots: [LocalSnapshot]?, snapshotNote: String? = nil) {
        self.container = container; self.volumeName = volumeName; self.purgeable = purgeable
        self.snapshots = snapshots; self.snapshotNote = snapshotNote
    }

    /// Bar segments, largest meaning first. Volumes are grouped by role; purgeable space is carved out of the Data
    /// volume (that's where it lives). "Overhead" is whatever the container's size minus its free space and the
    /// volumes' totals leaves (APFS metadata and space reserved by the container), shown only when positive. Zero-size
    /// parts are dropped.
    public var segments: [StorageSegment] {
        func sum(_ match: (APFSVolumeUsage) -> Bool) -> UInt64 { container.volumes.filter(match).reduce(0) { $0 + $1.used } }
        func has(_ v: APFSVolumeUsage, _ role: String) -> Bool { v.roles.contains(role) }
        let known = ["Data", "System", "Preboot", "Recovery", "VM", "Update"]
        let dataAll = sum { has($0, "Data") }
        let purge = min(purgeable ?? 0, dataAll)
        let other = sum { v in !known.contains { has(v, $0) } }
        var s: [StorageSegment] = [
            .init(kind: .data, title: "Your data", bytes: dataAll - purge,
                  explanation: "The Data volume: apps you installed, documents, photos, mail, caches, local snapshots and everything else that isn't macOS itself. This is most of what Storage settings calls \"System Data\" too."),
            .init(kind: .purgeable, title: "Purgeable", bytes: purge,
                  explanation: "Inside the Data volume, but macOS can delete it on its own when space runs low: caches it manages, local Time Machine snapshots and iCloud files it can download again. Finder counts it as free."),
            .init(kind: .system, title: "macOS", bytes: sum { has($0, "System") },
                  explanation: "The sealed, read-only system volume. Only a macOS update changes it."),
            .init(kind: .preboot, title: "Preboot", bytes: sum { has($0, "Preboot") },
                  explanation: "Files needed to start up: boot loaders, the FileVault unlock screen and, on Apple silicon, the bulk of the cryptex that ships Safari and system libraries. Managed by macOS."),
            .init(kind: .recovery, title: "Recovery", bytes: sum { has($0, "Recovery") },
                  explanation: "macOS Recovery, used to repair or reinstall macOS. Managed by macOS."),
            .init(kind: .vm, title: "Swap (VM)", bytes: sum { has($0, "VM") },
                  explanation: "Swap files and, on Intel Macs, the sleep image. It grows when memory runs short and shrinks after a restart."),
            .init(kind: .update, title: "Update", bytes: sum { has($0, "Update") },
                  explanation: "Staging space for macOS updates. It is emptied after an update installs."),
            .init(kind: .otherVolumes, title: "Other volumes", bytes: other,
                  explanation: "Other volumes in this container (another macOS install or a volume you added)."),
        ]
        let claimed = s.reduce(0) { $0 + $1.bytes } + container.free
        if container.capacity > claimed {
            s.append(.init(kind: .overhead, title: "APFS overhead", bytes: container.capacity - claimed,
                           explanation: "Space the container uses for its own bookkeeping and reserves; no volume reports it."))
        }
        s.append(.init(kind: .free, title: "Free", bytes: container.free,
                       explanation: "Not used by any volume. Finder's \"available\" figure is this plus purgeable."))
        return s.filter { $0.bytes > 0 }
    }

    public var timeMachineSnapshots: [LocalSnapshot] { (snapshots ?? []).filter { $0.kind == .timeMachine } }
}
