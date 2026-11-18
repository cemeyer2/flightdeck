// Tests for the Disk Space › "What's using my disk" parsers: diskutil plists, tmutil and simctl output (trimmed from
// real output, UUIDs replaced), the stacked-bar arithmetic, plus a live smoke test that skips where diskutil can't
// answer.
import XCTest
@testable import FlightDeckCore

final class StorageBreakdownTests: XCTestCase {
    static func vol(_ dev: String, _ name: String, _ role: String?, _ used: Int) -> String {
        """
        <dict><key>CapacityInUse</key><integer>\(used)</integer><key>DeviceIdentifier</key><string>\(dev)</string>
        <key>Name</key><string>\(name)</string><key>Roles</key><array>\(role.map { "<string>\($0)</string>" } ?? "")</array></dict>
        """
    }
    static let apfsList = """
    <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Containers</key><array>
    <dict><key>CapacityCeiling</key><integer>524288000</integer><key>CapacityFree</key><integer>503193600</integer>
    <key>ContainerReference</key><string>disk1</string><key>Volumes</key><array>\(vol("disk1s1", "iSCPreboot", "Preboot", 6131712))</array></dict>
    <dict><key>CapacityCeiling</key><integer>1000000000000</integer><key>CapacityFree</key><integer>100000000000</integer>
    <key>ContainerReference</key><string>disk3</string><key>Volumes</key><array>
    \(vol("disk3s1", "Macintosh HD", "System", 14_000_000_000))
    \(vol("disk3s2", "Preboot", "Preboot", 19_000_000_000))
    \(vol("disk3s3", "Recovery", "Recovery", 3_000_000_000))
    \(vol("disk3s4", "Update", "Update", 1_000_000_000))
    \(vol("disk3s5", "Data", "Data", 850_000_000_000))
    \(vol("disk3s6", "VM", "VM", 4_000_000_000))
    \(vol("disk3s7", "Scratch", nil, 2_000_000_000))
    <dict><key>DeviceIdentifier</key><string>disk3s8</string><key>Name</key><string>NoSize</string></dict>
    </array></dict></array></dict></plist>
    """

    func testAPFSList() throws {
        let cs = try XCTUnwrap(StorageParse.apfsContainers(Data(Self.apfsList.utf8)))
        XCTAssertEqual(cs.map(\.reference), ["disk1", "disk3"])
        let c = cs[1]
        XCTAssertEqual(c.capacity, 1_000_000_000_000); XCTAssertEqual(c.free, 100_000_000_000)
        // The volume without CapacityInUse is dropped, not shown as 0.
        XCTAssertEqual(c.volumes.count, 7)
        XCTAssertEqual(c.volumes.first { $0.roles == ["Data"] }?.used, 850_000_000_000)
        XCTAssertNil(StorageParse.apfsContainers(Data("not a plist".utf8)))
    }

    func testStartupInfo() throws {
        let info = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>APFSContainerReference</key><string>disk3</string>
        <key>VolumeName</key><string>Macintosh HD</string><key>FreeSpace</key><integer>0</integer></dict></plist>
        """
        let s = try XCTUnwrap(StorageParse.startupContainer(Data(info.utf8)))
        XCTAssertEqual(s.container, "disk3"); XCTAssertEqual(s.volumeName, "Macintosh HD")
        XCTAssertNil(StorageParse.startupContainer(Data("<plist version=\"1.0\"><dict/></plist>".utf8)))
    }

    func testSegmentsAddUpAndCarvePurgeable() throws {
        let c = try XCTUnwrap(StorageParse.apfsContainers(Data(Self.apfsList.utf8))?[1])
        let b = StorageBreakdown(container: c, volumeName: "Macintosh HD", purgeable: 30_000_000_000, snapshots: [])
        let seg = Dictionary(uniqueKeysWithValues: b.segments.map { ($0.kind, $0.bytes) })
        XCTAssertEqual(seg[.data], 820_000_000_000)
        XCTAssertEqual(seg[.purgeable], 30_000_000_000)
        XCTAssertEqual(seg[.system], 14_000_000_000)
        XCTAssertEqual(seg[.otherVolumes], 2_000_000_000)
        XCTAssertEqual(seg[.free], 100_000_000_000)
        // Volumes 893 GB + free 100 GB of 1 TB: the remaining 7 GB is container overhead.
        XCTAssertEqual(seg[.overhead], 7_000_000_000)
        XCTAssertEqual(b.segments.reduce(0) { $0 + $1.bytes }, c.capacity)
        // Unknown purgeable: no purgeable segment (not a 0 one), Data keeps everything.
        let u = StorageBreakdown(container: c, volumeName: nil, purgeable: nil, snapshots: nil)
        XCTAssertNil(u.segments.first { $0.kind == .purgeable })
        XCTAssertEqual(u.segments.first { $0.kind == .data }?.bytes, 850_000_000_000)
        // Purgeable larger than Data (inconsistent figures) is capped rather than underflowing.
        let big = StorageBreakdown(container: c, volumeName: nil, purgeable: 2_000_000_000_000, snapshots: nil)
        XCTAssertEqual(big.segments.first { $0.kind == .purgeable }?.bytes, 850_000_000_000)
    }

    func testPurgeable() {
        XCTAssertEqual(StorageParse.purgeable(important: 150, available: 100), 50)
        XCTAssertEqual(StorageParse.purgeable(important: 90, available: 100), 0)
        XCTAssertNil(StorageParse.purgeable(important: 0, available: 100))   // not reported off the startup volume
        XCTAssertNil(StorageParse.purgeable(important: nil, available: 100))
        XCTAssertNil(StorageParse.purgeable(important: 100, available: nil))
    }

    func testLocalSnapshots() throws {
        let out = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2026-11-17-072255.local
        com.apple.TimeMachine.2026-11-18-064418.local
        com.apple.os.update-182F06D70C9D02A9
        com.apple.os.update-MSUPrepareUpdate
        """
        let s = try XCTUnwrap(StorageParse.localSnapshots(out))
        XCTAssertEqual(s.map(\.kind), [.timeMachine, .timeMachine, .osUpdate, .osUpdate])
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: try XCTUnwrap(s[0].date))
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 11, 17, 7, 22, 55])
        XCTAssertNil(s[2].date)
        XCTAssertEqual(StorageParse.localSnapshots("Snapshots for volume group containing disk /:\n"), [])
        XCTAssertNil(StorageParse.localSnapshots("No such file or directory"))
        XCTAssertNil(StorageParse.localSnapshots(""))
    }

    func testSimctlDevicesAndRuntimes() throws {
        let devices = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-0":[
          {"udid":"A","name":"iPhone 15","state":"Shutdown","isAvailable":true},
          {"udid":"B","name":"iPad","state":"Booted","isAvailable":false,"availabilityError":"runtime profile not found"},
          {"name":"no udid"}]}}
        """
        let d = try XCTUnwrap(SimctlParse.devices(Data(devices.utf8)))
        XCTAssertEqual(d.map(\.udid), ["A", "B"])
        XCTAssertEqual(d.filter { !$0.isAvailable }.map(\.name), ["iPad"])
        XCTAssertEqual(d[1].availabilityError, "runtime profile not found")
        XCTAssertNil(SimctlParse.devices(Data("[]".utf8)))
        let runtimes = """
        {"1111":{"runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-17-0","version":"17.0",
                 "platformIdentifier":"com.apple.platform.iphonesimulator","state":"Ready","sizeBytes":7238325413},
         "2222":{"runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.watchOS-10-0","state":"Ready"}}
        """
        let r = try XCTUnwrap(SimctlParse.runtimes(Data(runtimes.utf8)))
        XCTAssertEqual(r.map(\.version), ["17.0", nil])
        XCTAssertEqual(r[0].sizeBytes, 7_238_325_413)
        XCTAssertNil(r[1].sizeBytes)   // not reported stays unknown
        XCTAssertEqual(SimctlParse.runtimes(Data("{\n\n}".utf8))?.count, 0)
    }

    func testBrewDryRun() {
        let out = """
        Would remove: /Users/me/Library/Caches/Homebrew/wget--1.24.5.bottle.tar.gz (1.2MB)
        Would remove: /opt/homebrew/Cellar/cryptography/42.0.8 (149 files, 4.5MB)
        ==> This operation would free approximately 5.7MB of disk space.
        """
        XCTAssertEqual(BrewParse.dryRunPaths(out), ["/Users/me/Library/Caches/Homebrew/wget--1.24.5.bottle.tar.gz",
                                                    "/opt/homebrew/Cellar/cryptography/42.0.8"])
        XCTAssertEqual(BrewParse.dryRunEstimate(out), "5.7MB")
        XCTAssertNil(BrewParse.dryRunEstimate(""))
    }

    /// Runs the real simctl, if Xcode is the selected developer directory (it isn't on most CI images).
    func testLiveSimctl() throws {
        guard let simctl = DevTools.simctlPath() else { throw XCTSkip("simctl isn't available") }
        let out = try XCTUnwrap(DevTools.run(simctl, ["list", "-j", "devices"], timeout: 60))
        XCTAssertNotNil(SimctlParse.devices(Data(out.output.utf8)))
    }

    /// Reads this Mac's startup disk. Skips where diskutil can't describe an APFS startup disk (some CI images).
    func testLiveBreakdown() throws {
        guard case .success(let b) = StorageBreakdownReader.read() else { throw XCTSkip("diskutil gave no APFS startup container here") }
        XCTAssertGreaterThan(b.container.capacity, 0)
        XCTAssertFalse(b.segments.isEmpty)
        XCTAssertLessThanOrEqual(b.segments.filter { $0.kind != .overhead }.reduce(0) { $0 + $1.bytes }, b.container.capacity + b.container.capacity / 100)
    }
}
