import XCTest
@testable import FlightDeckHelperProtocol

enum HelperFixtures {
    // SYNTHETIC: replace with a capture from a Developer ID build
    static let dumpbtm = """
    ========================
     Records for UID 501 : 3A1F0B6C-0000-0000-0000-000000000000
    ========================

     ServiceManagement migrated: true
     SharedFileList migrated: true

     Items:

     #1:
                     UUID: 11111111-2222-3333-4444-555555555555
                     Name: Docker
           Developer Name: Docker Inc
                     Type: app (0x2)
                    Flags: [  ] (0)
              Disposition: [enabled, allowed, visible, notified] (0xb)
               Identifier: 2.com.docker.docker
                      URL: file:///Applications/Docker.app/
               Generation: 1

     #2:
                     UUID: 66666666-7777-8888-9999-000000000000
                     Name: com.example.updater
           Developer Name: Example Corp
                     Type: legacy daemon (0x10010)
              Disposition: [disabled, allowed, visible, notified] (0xa)
               Identifier: 16.com.example.updater
                      URL: file:///Library/LaunchDaemons/com.example.updater.plist
    """

    // SYNTHETIC: replace with a capture from a Developer ID build
    static let profilesAll = """
    _computerlevel[1] attribute: profileIdentifier: com.example.wifi
    _computerlevel[1] attribute: name: Office Wi-Fi
    charlie[1] attribute: profileIdentifier: com.example.user
    There are 1 system configuration profiles installed
    """

    // SYNTHETIC: replace with a capture from a Developer ID build. On this Mac (macOS 26) no tmutil subcommand
    // reports local snapshot sizes without root, so the sized line format below is an assumption.
    static let tmutilSized = """
    Snapshots for volume group containing disk /:
    com.apple.TimeMachine.2026-11-17-072255.local (1.5 GB)
    com.apple.os.update-MSUPrepareUpdate (123456 bytes)
    """
}

final class HelperParserTests: XCTestCase {
    func testDumpbtmParsesItems() {
        let items = HelperParsers.backgroundItems(HelperFixtures.dumpbtm)
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?.first?.enabled, true)
        XCTAssertEqual(items?.first?.name, "Docker")
        XCTAssertEqual(items?.first?.type, "app")
        XCTAssertEqual(items?.first?.developer, "Docker Inc")
        XCTAssertEqual(items?.first?.url, "file:///Applications/Docker.app/")
        XCTAssertEqual(items?.last?.enabled, false)
        XCTAssertEqual(items?.last?.type, "legacy daemon")
    }

    func testDumpbtmUnrecognisedIsNil() {
        XCTAssertNil(HelperParsers.backgroundItems("garbage"))
        XCTAssertNil(HelperParsers.backgroundItems(""))
    }

    func testProfilesDeviceScope() {
        let p = HelperParsers.deviceProfiles(HelperFixtures.profilesAll)
        XCTAssertEqual(p, [DeviceProfile(identifier: "com.example.wifi", name: "Office Wi-Fi", scope: "device")])
    }

    func testProfilesNoneInstalled() {
        XCTAssertEqual(HelperParsers.deviceProfiles("There are no configuration profiles installed in the system domain"), [])
        XCTAssertNil(HelperParsers.deviceProfiles("garbage"))
    }

    func testSnapshotSizes() {
        let s = HelperParsers.snapshotSizes(HelperFixtures.tmutilSized)
        XCTAssertEqual(s, [SnapshotSize(name: "com.apple.TimeMachine.2026-11-17-072255.local", bytes: 1_500_000_000),
                           SnapshotSize(name: "com.apple.os.update-MSUPrepareUpdate", bytes: 123_456)])
        // Today's unsized output is recognised but carries no sizes.
        XCTAssertEqual(HelperParsers.snapshotSizes("Snapshots for volume group containing disk /:\ncom.apple.os.update-ABC\n"), [])
        XCTAssertNil(HelperParsers.snapshotSizes("garbage"))
    }

    func testProcArgs() {
        var buf: [UInt8] = []
        var argc: Int32 = 2
        withUnsafeBytes(of: &argc) { buf += $0 }
        buf += Array("/bin/x\0\0\0".utf8)
        buf += Array("a\0".utf8)
        buf += Array("\0".utf8)
        buf += Array("K=V\0".utf8)
        buf += Array("\0".utf8)
        let r = HelperParsers.procArgs(buf)
        XCTAssertEqual(r?.args, ["a", ""])
        XCTAssertEqual(r?.env, ["K=V"])
        XCTAssertNil(HelperParsers.procArgs([1, 2]))
    }
}
