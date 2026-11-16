import XCTest
@testable import FlightDeckCore

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

import IOKit.pwr_mgt
final class ProcessExtrasTests: XCTestCase {
    func testCountersKindAndAssertions() {
        let c = ProcessInspector.counters(getpid())
        XCTAssertNotNil(c); XCTAssertGreaterThan(c!.unixSyscalls, 0); XCTAssertGreaterThan(c!.peakFootprint ?? 0, 0)
        XCTAssertEqual(ProcessSampler.isTranslated(getpid()), false)
        var id: IOPMAssertionID = 0
        XCTAssertEqual(IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "flightdeck test" as CFString, &id), kIOReturnSuccess)
        defer { IOPMAssertionRelease(id) }
        let mine = PowerAssertions.byPID()[getpid()]
        XCTAssertEqual(mine?.first?.name, "flightdeck test")
        XCTAssertTrue(mine?.first?.preventsSystemSleep ?? false)
        let s = Sampler().sample().processes.first { $0.pid == getpid() }
        XCTAssertNotNil(s?.powerAssertions)
        XCTAssertEqual(s?.translated, false)
    }
}

final class DiagnosticReportTests: XCTestCase {
    func write(_ name: String, _ s: String, in dir: URL) { try! s.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }

    func testParsesKindsAndFindings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        let ts = DiagnosticReports.headerDate.string(from: now.addingTimeInterval(-600))
        for i in 0..<2 {
            write("Foo-\(i).ips", #"{"app_name":"Foo","timestamp":"\#(ts)","bug_type":"309","name":"Foo"}"# + "\n{\n  \"exception\" : {\"codes\":\"0x1\", \"type\" : \"EXC_BAD_ACCESS\", \"signal\" : \"SIGSEGV\"}\n}", in: dir)
        }
        write("ExcUserFault_bar.ips", #"{"is_simulated":1,"app_name":"bar","timestamp":"\#(ts)","bug_type":"309"}"# + "\n{}", in: dir)
        write("JetsamEvent-x.ips", #"{"bug_type":"298","timestamp":"\#(ts)"}"# + "\n{}", in: dir)
        write("curl_x.diag", "Date/Time:        \(DiagnosticReports.textDate.string(from: now))\nCommand:          curl\nEvent:            disk writes\nWrites:           8589.94 MB of file backed memory dirtied\n", in: dir)
        let r = DiagnosticReports.scan(since: now.addingTimeInterval(-3600), directories: [dir.path])
        XCTAssertEqual(r.count, 5)
        XCTAssertEqual(r.filter { $0.kind == .crash }.count, 2)
        XCTAssertEqual(r.first { $0.kind == .crash }?.summary, "EXC_BAD_ACCESS / SIGSEGV")
        XCTAssertEqual(r.first { $0.process == "bar" }?.kind, .userFault)
        XCTAssertEqual(r.first { $0.process == "curl" }?.kind, .diskWrites)
        XCTAssertTrue(r.first { $0.process == "curl" }?.summary?.hasPrefix("8589.94 MB") ?? false)
        XCTAssertEqual(r.first { $0.kind == .jetsam }?.process, "System")
        let f = DiagnosticReports.findings(r, now: now)
        XCTAssertEqual(f.map(\.title), ["Foo crashed 2 times in the last 24 hours"])
        print("REAL", DiagnosticReports.scan(since: now.addingTimeInterval(-7 * 86_400)).prefix(6).map { "\($0.kind.rawValue): \($0.process) \($0.summary ?? "")" })
    }
}
