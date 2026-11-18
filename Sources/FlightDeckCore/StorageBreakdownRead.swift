import Foundation

// The I/O half of the startup-disk breakdown: runs diskutil and tmutil (no root, no folder access, well under a second)
// and reads the startup volume's capacity figures. Parsing is in StorageBreakdown.swift.

public enum StorageBreakdownReader {
    /// Reads the breakdown, or returns why it couldn't (not APFS, diskutil missing or unrecognised output).
    /// Blocking; call off the main thread.
    public static func read() -> Result<StorageBreakdown, StorageReadError> {
        guard let info = Shell.run("/usr/sbin/diskutil", ["info", "-plist", "/"]),
              let startup = StorageParse.startupContainer(Data(info.utf8)) else {
            return .failure(.init(reason: "diskutil didn't report an APFS container for the startup disk."))
        }
        guard let list = Shell.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 20),
              let containers = StorageParse.apfsContainers(Data(list.utf8)) else {
            return .failure(.init(reason: "diskutil apfs list could not be run or its output wasn't recognised."))
        }
        guard let container = containers.first(where: { $0.reference == startup.container }) else {
            return .failure(.init(reason: "Container \(startup.container) wasn't in diskutil's APFS list."))
        }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
        let purge = StorageParse.purgeable(important: v?.volumeAvailableCapacityForImportantUsage,
                                           available: v?.volumeAvailableCapacity.map(Int64.init))
        let (snaps, note) = snapshots()
        return .success(StorageBreakdown(container: container, volumeName: startup.volumeName, purgeable: purge,
                                         snapshots: snaps, snapshotNote: note))
    }

    /// Local snapshots of the startup volume group. tmutil can list them without root; it can't size them (that needs
    /// `tmutil` as root or `diskutil apfs listSnapshots`, which doesn't report sizes either), so none is given.
    static func snapshots() -> ([LocalSnapshot]?, String?) {
        guard let out = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 20) else {
            return (nil, "tmutil could not be run.")
        }
        guard let list = StorageParse.localSnapshots(out) else { return (nil, "tmutil's output wasn't recognised.") }
        return (list, nil)
    }
}

public struct StorageReadError: Error, Sendable { public var reason: String }
