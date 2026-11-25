import XCTest
@testable import FlightDeckCore
import FlightDeckHelperProtocol

final class HelperReadersTests: XCTestCase {
    static let lsofF = """
    p123
    cSafari
    f10
    PTCP
    n10.0.0.5:5000->1.2.3.4:443
    TST=ESTABLISHED
    TQR=0
    f11
    PUDP
    n*:5353
    f12
    PUDP
    n*:5353
    p1
    claunchd
    f7
    PTCP
    n*:22
    TST=LISTEN
    """

    func testListeningViaHelper() {
        let fake = FakeHelperClient()
        let s = HelperSession.unlockedForTests(fake)
        fake.replies["listeningSockets"] = .toolText("#netstat\n" + ListeningPortsTests.tcp + "\n#udp\n" + ListeningPortsTests.udp)
        let scan = ListeningPorts.scan(helper: s)
        XCTAssertEqual(scan.coverage, .allProcesses)
        XCTAssertTrue(scan.viaHelper)
        XCTAssertEqual(scan.sockets.count, 5)   // 4 TCP listeners + 1 unconnected UDP socket
        XCTAssertTrue(scan.sockets.contains { $0.proto == "UDP" && $0.port == 5353 })
    }

    func testListeningLsofViaHelper() throws {
        let scan = try XCTUnwrap(ListeningPorts.parseHelper("#lsof\n" + Self.lsofF))
        XCTAssertTrue(scan.viaHelper)
        XCTAssertTrue(scan.sockets.contains { $0.pid == 1 && $0.port == 22 })
        XCTAssertNil(ListeningPorts.parseHelper("garbage"))
    }

    func testListeningLockedFallsBack() {
        let fake = FakeHelperClient()
        fake.replies["hello"] = .hello(HelperHello(version: 1, rightInPlace: true, eligible: true))
        fake.replies["status"] = .status(HelperServiceStatus(unlocked: true, holderAlive: true, agentContents: false))
        let s = HelperSession(client: fake, authorization: { nil })
        s.connect(); s.refreshStatus()
        let scan = ListeningPorts.scan(helper: s)
        XCTAssertFalse(scan.viaHelper)
        XCTAssertTrue(fake.calls(of: "listeningSockets").isEmpty)
    }

    func testConnectionsParseUnchanged() {
        let items = Connections.parse(Self.lsofF)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0].process, "Safari")
        XCTAssertEqual(items[0].local, "10.0.0.5:5000")
        XCTAssertEqual(items[0].remote, "1.2.3.4:443")
        XCTAssertEqual(items[0].state, "ESTABLISHED")
        XCTAssertEqual(items[1].state, "—")
        XCTAssertEqual(items[2].occurrence, 2)
        XCTAssertEqual(items[3].pid, 1)
        XCTAssertEqual(items[3].state, "LISTEN")
    }

    func testConnectionsViaHelper() {
        let fake = FakeHelperClient()
        let s = HelperSession.unlockedForTests(fake)
        fake.replies["internetSockets"] = .toolText(Self.lsofF)
        let r = Connections.list(helper: s)
        XCTAssertTrue(r.viaHelper)
        XCTAssertEqual(r.items.count, 4)
    }

    func testSnapshotSizesMatched() {
        let snaps = [LocalSnapshot(name: "a", kind: .other, date: nil), LocalSnapshot(name: "b", kind: .other, date: nil),
                     LocalSnapshot(name: "c", kind: .other, date: nil)]
        let b = StorageBreakdown(container: APFSContainerUsage(reference: "disk3", capacity: 1, free: 1, volumes: []), volumeName: nil,
                                 purgeable: nil, snapshots: snaps)
        let out = StorageBreakdownReader.withSizes(b, [SnapshotSize(name: "a", bytes: 10), SnapshotSize(name: "c", bytes: 30)])
        XCTAssertEqual(out.snapshots?.map(\.size), [10, nil, 30])
        XCTAssertTrue(out.snapshotsViaHelper)
        XCTAssertFalse(StorageBreakdownReader.withSizes(b, []).snapshotsViaHelper)
    }

    func testChangeReadersDropsLimitsWhenUnlocked() {
        let fake = FakeHelperClient()
        let s = HelperSession.unlockedForTests(fake)
        fake.replies["deviceProfiles"] = .profiles([DeviceProfile(identifier: "com.example.wifi", name: "Office Wi-Fi", scope: "device")])
        fake.replies["backgroundItems"] = .backgroundItems([
            BackgroundItem(identifier: "2.com.docker.docker", name: "Docker", type: "app", developer: "Docker Inc", enabled: true,
                           url: "file:///Applications/Docker.app/"),
            BackgroundItem(identifier: "16.com.example.updater", name: "updater", type: "legacy daemon", developer: nil, enabled: true, url: nil),
        ])
        let inv = ChangeReaders.read(previous: nil, helper: s)
        XCTAssertFalse(inv.limits.contains { $0.hasPrefix("Configuration profiles installed for the whole Mac") })
        XCTAssertFalse(inv.limits.contains { $0.hasPrefix("Login items and apps' background items") })
        XCTAssertTrue(inv.items.contains { $0.category == .profile && $0.key == "profile:com.example.wifi" && $0.scope == "This Mac" })
        XCTAssertTrue(inv.items.contains { $0.key == "btm:2.com.docker.docker" && $0.path == "/Applications/Docker.app" })
        XCTAssertFalse(inv.items.contains { $0.key == "btm:16.com.example.updater" })

        // Locked afterwards: the helper-only items are carried over rather than reported as removed, and the limits return.
        let locked = HelperSession(client: FakeHelperClient(), authorization: { nil })
        let next = ChangeReaders.read(previous: inv, helper: locked)
        XCTAssertTrue(next.items.contains { $0.key == "btm:2.com.docker.docker" })
        XCTAssertTrue(next.items.contains { $0.key == "profile:com.example.wifi" })
        XCTAssertTrue(next.limits.contains { $0.hasPrefix("Login items and apps' background items") })
        // Helper off: exactly what the app reads itself.
        XCTAssertFalse(ChangeReaders.read(previous: inv).items.contains { $0.key.hasPrefix("btm:") })
    }

    /// Unlocking for the first time, locking, and turning the helper off produce no events for the helper-only items;
    /// a real addition while both inventories include them still does.
    func testHelperCoverageChangeIsNoFlood() {
        let launchd = InventoryItem(category: .launchItem, key: "/Library/LaunchDaemons/a.plist", name: "a")
        let wifi = InventoryItem(category: .profile, key: "profile:com.example.wifi", name: "Office Wi-Fi", scope: ChangeReaders.deviceScope)
        let docker = InventoryItem(category: .launchItem, key: "btm:2.com.docker.docker", name: "Docker", scope: "Login Items (app)")
        let vpn = InventoryItem(category: .profile, key: "profile:com.example.vpn", name: "VPN", scope: ChangeReaders.deviceScope)
        func inv(_ t: Double, _ read: (items: [InventoryItem], profilesOK: Bool, itemsOK: Bool)?, previous: Inventory?) -> Inventory {
            var i = Inventory(time: Date(timeIntervalSince1970: t), items: [launchd])
            ChangeReaders.addHelperItems(read, to: &i, previous: previous)
            return i
        }
        let off = inv(1000, nil, previous: nil)
        let unlocked = inv(2000, ([wifi, docker], true, true), previous: off)
        XCTAssertEqual(ChangeDiff.diff(old: off, new: unlocked), [], "first unlock adds nothing")
        let locked = inv(3000, ([], false, false), previous: unlocked)
        XCTAssertEqual(locked.helperProfiles, true)
        XCTAssertEqual(ChangeDiff.diff(old: unlocked, new: locked), [], "locking carries over")
        let again = inv(4000, ([wifi, docker, vpn], true, true), previous: locked)
        XCTAssertEqual(ChangeDiff.diff(old: locked, new: again).map(\.item.key), ["profile:com.example.vpn"])
        let turnedOff = inv(5000, nil, previous: again)
        XCTAssertNil(turnedOff.helperBackgroundItems)
        XCTAssertEqual(ChangeDiff.diff(old: again, new: turnedOff), [], "turning the helper off removes nothing")
        // Locked from launch (helper on, never unlocked): nothing to carry, nothing to report on a later unlock.
        let lockedFirst = inv(6000, ([], false, false), previous: turnedOff)
        XCTAssertNil(lockedFirst.helperProfiles)
        XCTAssertEqual(ChangeDiff.diff(old: lockedFirst, new: inv(7000, ([wifi], true, true), previous: lockedFirst)), [])
    }

    func testRefusalFallsBack() {
        let fake = FakeHelperClient()
        let s = HelperSession.unlockedForTests(fake)
        fake.replies["listeningSockets"] = .refused(HelperRefusal(code: .toolFailed, message: "x"))
        let scan = ListeningPorts.scan(helper: s)
        XCTAssertFalse(scan.viaHelper)
        if case .allProcesses = ListeningPorts.scan().coverage { XCTAssertEqual(scan.coverage, .allProcesses) }
    }
}
