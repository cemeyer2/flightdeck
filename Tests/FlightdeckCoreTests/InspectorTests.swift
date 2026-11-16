import XCTest
@testable import FlightdeckCore

final class InspectorTests: XCTestCase {
    func testOwnProcessDetails() throws {
        // open a listening TCP socket and a file so they show up
        let s = socket(AF_INET, SOCK_STREAM, 0); defer { close(s) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(s, 1)
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("insp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: f.path, contents: Data())
        let h = try FileHandle(forReadingFrom: f); defer { try? h.close() }

        let d = ProcessInspector.details(pid: getpid(), path: CommandLine.arguments[0])
        XCTAssertFalse(d.arguments.value?.isEmpty ?? true)
        XCTAssertTrue(d.environment.value?.contains { $0.hasPrefix("PATH=") } ?? false)
        XCTAssertEqual(d.cwd.value, FileManager.default.currentDirectoryPath)
        XCTAssertTrue(d.files.value?.contains { $0.description.hasSuffix(f.lastPathComponent) } ?? false)
        let l = d.sockets.first { $0.proto == "TCP" && $0.state == "LISTEN" }
        XCTAssertNotNil(l, "listening socket: \(d.sockets)")
        XCTAssertTrue(l?.local.hasPrefix("127.0.0.1:") ?? false)
        XCTAssertGreaterThan(d.threads.value?.count ?? 0, 0)
        XCTAssertEqual(d.ancestry.first?.pid, getpid())
        XCTAssertEqual(d.ancestry.last?.pid, 1)
        XCTAssertNotNil(d.nice)
    }

    func testSignatureAndRestricted() {
        let sig = ProcessInspector.signature("/usr/bin/yes")
        XCTAssertEqual(sig?.isApple, true)
        XCTAssertEqual(sig?.valid, true)
        if getuid() != 0 {
            let d = ProcessInspector.details(pid: 1, path: "/sbin/launchd")
            XCTAssertNil(d.environment.value, "another user's environment must be unavailable, not empty")
        }
    }
}

final class DriveHealthTests: XCTestCase {
    func testReadsInternalSSD() {
        let d = DriveHealthReader.read()
        print("DRIVES", d)
        guard let first = d.first else { return }   // Macs without NVMe SMART simply report nothing
        XCTAssertGreaterThan(first.bytesWritten, 0)
        XCTAssertGreaterThan(first.powerOnHours, 0)
        XCTAssert((0...150).contains(first.temperature))
    }
}

final class SMCTests: XCTestCase {
    func testFansDecode() {
        let f = SMC.shared.fans()
        print("FANS", f)
        for fan in f { XCTAssert((0...20_000).contains(fan.rpm)); if let m = fan.maxRPM { XCTAssertGreaterThan(m, 500) } }
    }
}
