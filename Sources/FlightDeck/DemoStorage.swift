// Demo mode for Disk Space › "What's using my disk": an invented 1 TB startup disk and invented space hogs under an
// invented home folder (/Users/demo). Nothing here reads this Mac, and the model refuses every cleanup in demo mode.
import Foundation
import FlightDeckCore

extension Demo {
    static let demoHome = "/Users/demo"
    static let gb: UInt64 = 1_000_000_000

    static func storageBreakdown() -> StorageBreakdown {
        let vols = [
            APFSVolumeUsage(name: "Macintosh HD", device: "disk3s1", roles: ["System"], used: 12 * gb),
            APFSVolumeUsage(name: "Preboot", device: "disk3s2", roles: ["Preboot"], used: 9 * gb),
            APFSVolumeUsage(name: "Recovery", device: "disk3s3", roles: ["Recovery"], used: 2 * gb),
            APFSVolumeUsage(name: "Update", device: "disk3s4", roles: ["Update"], used: 1 * gb),
            APFSVolumeUsage(name: "Data", device: "disk3s5", roles: ["Data"], used: 612 * gb),
            APFSVolumeUsage(name: "VM", device: "disk3s6", roles: ["VM"], used: 4 * gb),
        ]
        let c = APFSContainerUsage(reference: "disk3", capacity: 994 * gb, free: 351 * gb, volumes: vols)
        let day: TimeInterval = 86_400, now = Date()
        let snaps = [-1.6, -0.9, -0.1].map { d -> LocalSnapshot in
            let t = now.addingTimeInterval(d * day)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
            return LocalSnapshot(name: "com.apple.TimeMachine.\(f.string(from: t)).local", kind: .timeMachine, date: t)
        } + [LocalSnapshot(name: "com.apple.os.update-DEMO", kind: .osUpdate, date: nil)]
        return StorageBreakdown(container: c, volumeName: "Macintosh HD", purgeable: 38 * gb, snapshots: snaps)
    }

    /// One invented result per catalog category, in catalog order. A few show the states the real analysis can produce:
    /// a folder macOS wouldn't open (Messages), a category with nothing on this "Mac" (VMs) and a partial size (caches).
    static func hogResults() -> [HogResult] {
        let mb: UInt64 = 1_000_000, now = Date()
        func size(_ b: UInt64, _ unreadable: Int = 0) -> SizeResult { .size(bytes: b, unreadable: unreadable) }
        func folder(_ path: String, _ items: [(String, UInt64, Double)], unreadable: Int = 0) -> HogLocation {
            let full = PathTemplate.expandHome(path, home: demoHome)
            let list = items.map { HogItem(path: full + "/" + $0.0, size: size($0.1), added: now.addingTimeInterval(-$0.2 * 86_400)) }
            return HogLocation(path: full, size: size(list.reduce(0) { $0 + ($1.size.bytes ?? 0) }, unreadable), items: list)
        }
        let locations: [String: [HogLocation]] = [
            "caches": [folder("~/Library/Caches", [("com.apple.Safari", 1_840 * mb, 3), ("com.spotify.client", 3_120 * mb, 40),
                                                  ("com.tinyspeck.slackmacgap", 960 * mb, 12), ("com.apple.python", 210 * mb, 100)], unreadable: 3)],
            "logs": [folder("~/Library/Logs", [("DiagnosticReports", 140 * mb, 30), ("JetBrains", 620 * mb, 80)])],
            "trash": [folder("~/.Trash", [("Old Project.zip", 2_400 * mb, 5), ("IMG_0042.mov", 1_100 * mb, 2)])],
            "downloads": [folder("~/Downloads", [("Xcode_16.xip", 11_800 * mb, 210), ("Ubuntu-24.04.iso", 6_100 * mb, 160),
                                                 ("Tax return.pdf", 3 * mb, 120), ("screenshot.png", 2 * mb, 4)])],
            "iosBackups": [folder("~/Library/Application Support/MobileSync/Backup", [("00008110-DEMO", 48_200 * mb, 400)])],
            "derivedData": [folder("~/Library/Developer/Xcode/DerivedData", [("MyApp-demo", 6_400 * mb, 1), ("OldExperiment-demo", 2_900 * mb, 190)])],
            "archives": [folder("~/Library/Developer/Xcode/Archives", [("2026-03-02", 1_700 * mb, 260)])],
            "deviceSupport": [folder("~/Library/Developer/Xcode/iOS DeviceSupport", [("iPhone15,2 18.1 (22B83)", 5_100 * mb, 300), ("iPhone15,2 19.0 (23A341)", 5_400 * mb, 60)])],
            "simDevices": [folder("~/Library/Developer/CoreSimulator/Devices", [("A1B2C3D4-DEMO", 3_300 * mb, 30), ("E5F6A7B8-DEMO", 1_900 * mb, 300)])],
            "simRuntimes": [folder("/Library/Developer/CoreSimulator/Images", [("iOS_23A339.dmg", 8_200 * mb, 70)])],
            "previews": [folder("~/Library/Developer/Xcode/UserData/Previews", [("Simulator Devices", 2_200 * mb, 20)])],
            "containers": [folder("~/Library/Containers/com.docker.docker/Data/vms", [("0", 24_600 * mb, 300)])],
            "homebrew": [folder("~/Library/Caches/Homebrew", [("downloads", 1_350 * mb, 9), ("Cask", 420 * mb, 30)])],
            "devCaches": [folder("~/.npm/_cacache", [("content-v2", 2_700 * mb, 8)]), folder("~/.gradle/caches", [("modules-2", 3_400 * mb, 50)])],
            "mailDownloads": [folder("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", [("D3F1-DEMO", 85 * mb, 15)])],
            "messages": [HogLocation(path: demoHome + "/Library/Messages/Attachments", size: .notReadable("macOS didn't allow access (System Settings › Privacy & Security › Full Disk Access or Files & Folders)"), items: [])],
            "photos": [folder("~/Pictures", [("Photos Library.photoslibrary", 71_300 * mb, 900)])],
            "installers": [folder("/Applications", [("Install macOS Sequoia.app", 15_100 * mb, 380)])],
            "vms": [],
        ]
        var out = SpaceHogCategory.catalog.map { HogResult(category: $0, locations: locations[$0.id] ?? []) }
        if let i = out.firstIndex(where: { $0.category.id == "simDevices" }) { out[i].notes = ["34 simulators, 9 unavailable (their runtime is no longer installed)."] }
        if let i = out.firstIndex(where: { $0.category.id == "simRuntimes" }) { out[i].notes = ["iOS-19-0 (19.0): 8.20 GB"] }
        return out
    }
}
