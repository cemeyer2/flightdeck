// Chrome tabs: the host-to-app socket (its path, the directory and stale-socket checks, peer credentials), the
// listener's per-connection protocol, and the built binary in native-host mode end to end.
import XCTest
import Darwin
import Security
@testable import FlightDeckCore

final class ChromeTabsSocketTests: XCTestCase {
    var dirs: [URL] = []
    override func tearDown() { for d in dirs { try? FileManager.default.removeItem(at: d) }; dirs = [] }

    /// A short temporary directory (socket paths must stay under 104 bytes).
    func tempDir(mode: mode_t = 0o700) -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fdct-" + UUID().uuidString.prefix(8))
        mkdir(d.path, mode); chmod(d.path, mode)
        dirs.append(d)
        return d
    }

    func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; usleep(10_000) }
        return cond()
    }

    // MARK: Path and filesystem checks

    func testSocketPathDefault() {
        let u = ChromeTabsSocket.socketURL(appSupport: URL(fileURLWithPath: "/Users/me/Library/Application Support"), tmpDir: "/var/t/", env: [:])
        XCTAssertEqual(u.path, "/Users/me/Library/Application Support/Flightdeck/ChromeTabs/chrome-tabs.sock")
    }

    func testSocketPathFallsBackWhenTooLong() {
        let long = "/" + String(repeating: "a", count: 119)
        let u = ChromeTabsSocket.socketURL(appSupport: URL(fileURLWithPath: long), tmpDir: "/var/folders/xy/T/", env: [:])
        XCTAssertTrue(u.path.hasPrefix("/var/folders/xy/T/"), u.path)
        XCTAssertEqual(u.lastPathComponent, "chrome-tabs.sock")
        XCTAssertLessThanOrEqual(u.path.utf8.count, 103)
    }

    func testSocketPathEnvOverride() {
        let u = ChromeTabsSocket.socketURL(appSupport: URL(fileURLWithPath: "/a"), tmpDir: "/t", env: ["FLIGHTDECK_CHROME_SOCKET_DIR": "/tmp/x"])
        XCTAssertEqual(u.path, "/tmp/x/chrome-tabs.sock")
    }

    func testPrepareDirectoryRejectsSymlinkWrongModeAndFile() throws {
        let base = tempDir()
        let fresh = base.appendingPathComponent("new")
        XCTAssertNoThrow(try ChromeTabsSocket.prepareDirectory(fresh))
        var st = stat(); lstat(fresh.path, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o700, "created 0700")
        XCTAssertNoThrow(try ChromeTabsSocket.prepareDirectory(fresh), "an existing good directory is fine")

        let open = base.appendingPathComponent("open"); mkdir(open.path, 0o755); chmod(open.path, 0o755)
        XCTAssertThrowsError(try ChromeTabsSocket.prepareDirectory(open)) { XCTAssertEqual($0 as? ChromeTabsSocket.SetupError, .wrongMode(0o755)) }

        let link = base.appendingPathComponent("link"); symlink(fresh.path, link.path)
        XCTAssertThrowsError(try ChromeTabsSocket.prepareDirectory(link)) { XCTAssertEqual($0 as? ChromeTabsSocket.SetupError, .symlink) }

        let file = base.appendingPathComponent("file"); FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertThrowsError(try ChromeTabsSocket.prepareDirectory(file)) { XCTAssertEqual($0 as? ChromeTabsSocket.SetupError, .notDirectory) }
    }

    func testRemoveStaleSocketOnlyUnlinksOwnedSocket() throws {
        let d = tempDir()
        let missing = d.appendingPathComponent("none.sock")
        XCTAssertNoThrow(try ChromeTabsSocket.removeStaleSocket(missing))

        let file = d.appendingPathComponent("file.sock"); FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertThrowsError(try ChromeTabsSocket.removeStaleSocket(file)) { XCTAssertEqual($0 as? ChromeTabsSocket.SetupError, .staleNotSocket) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let link = d.appendingPathComponent("link.sock"); symlink(file.path, link.path)
        XCTAssertThrowsError(try ChromeTabsSocket.removeStaleSocket(link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // A real (stale) socket we own is removed.
        let sock = d.appendingPathComponent("s.sock")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in _ = sock.path.withCString { strncpy(p.baseAddress!.assumingMemoryBound(to: CChar.self), $0, p.count - 1) } }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(r, 0); close(fd)
        XCTAssertNoThrow(try ChromeTabsSocket.removeStaleSocket(sock))
        var st = stat()
        XCTAssertNotEqual(lstat(sock.path, &st), 0)
    }

    /// The browser identity taken from the host's parent must equal the one the sampler reports for that process, or
    /// the Engine's pruning would drop every table on the first sample.
    func testDerivedIdentityMatchesSampler() throws {
        let sampled = try XCTUnwrap(ProcessSampler().sample().first { $0.pid == getpid() })
        XCTAssertEqual(ProcessSampler.identity(of: getpid()), sampled.identity)
    }

    func testPeerOfSelfConnection() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let p = try XCTUnwrap(ChromePeerAuth.peer(of: fds[0]))
        XCTAssertEqual(p.pid, getpid())
        XCTAssertEqual(p.uid, getuid())
        XCTAssertNotNil(p.auditToken)
        XCTAssertNil(ChromePeerAuth.browser(ofHostPID: getpid()), "our parent isn't Google Chrome")
        // Our own signature satisfies our own requirement (skipped when the test runner is unsigned).
        if let req = ChromePeerAuth.ownRequirement() { XCTAssertTrue(ChromePeerAuth.isTrusted(p, requirement: req)) }
    }

    /// The host checks the listener before sending: our own process passes our requirement, and no requirement (an
    /// unsigned build) trusts nobody.
    func testHostChecksListener() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertFalse(ChromePeerAuth.isTrustedListener(fd: fds[1], requirement: nil))
        XCTAssertFalse(ChromePeerAuth.isTrustedListener(fd: -1, requirement: ChromePeerAuth.ownRequirement()))
        if let req = ChromePeerAuth.ownRequirement() { XCTAssertTrue(ChromePeerAuth.isTrustedListener(fd: fds[1], requirement: req)) }
        var other: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString("identifier \"com.example.not-flightdeck\"" as CFString, [], &other), errSecSuccess)
        XCTAssertFalse(ChromePeerAuth.isTrustedListener(fd: fds[1], requirement: try XCTUnwrap(other)))
    }

    // MARK: Listener

    let browserID = ProcessIdentity(pid: 4242, startTime: 77)

    func startListener(authorized: Bool = true) throws -> (ChromeTabsListener, ChromeTabStore, URL) {
        let sock = tempDir().appendingPathComponent("ct").appendingPathComponent("chrome-tabs.sock")
        let store = ChromeTabStore()
        let id = browserID
        let l = ChromeTabsListener(socket: sock, store: store, authorize: { _ in authorized ? id : nil })
        try l.start()
        addTeardownBlock { l.stop() }
        return (l, store, sock)
    }

    func send(_ fd: Int32, _ m: ChromeTabsMessage) { _ = ChromeFraming.writeFrame(fd: fd, m.encoded()) }
    let table = ChromeTabTable(seq: 1, tabs: [ChromeRawTab(tabId: 1, windowId: 1, active: true, audible: false, discarded: false,
                                                           url: "https://a.example/", title: "A", lastAccessed: 1,
                                                           frames: [ChromeRawFrame(frameId: 0, parentFrameId: -1, processId: 5, origin: "https://a.example")])])

    func testListenerRoundTrip() throws {
        let (_, store, sock) = try startListener()
        var st = stat(); lstat(sock.path, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        let fd = try XCTUnwrap(ChromeTabsSocket.connect(sock))
        send(fd, .origin(ChromeTabsConstants.allowedOrigins[0]))
        send(fd, .hello(protocol: 1, extensionVersion: "1.0.0"))
        send(fd, .tabs(table))
        XCTAssertTrue(waitUntil { store.tables().values.first == self.table })
        XCTAssertEqual(store.tables().keys.first?.browser, browserID)
        // A bad table drops the connection's previous one.
        _ = ChromeFraming.writeFrame(fd: fd, Data(#"{"type":"tabs","seq":2,"tabs":[{"tabId":1.5}]}"#.utf8))
        XCTAssertTrue(waitUntil { store.tables().isEmpty })
        XCTAssertFalse(store.hellos().isEmpty)
        close(fd)
        XCTAssertTrue(waitUntil { store.isEmpty }, "disconnect removes that connection")
    }

    func testListenerRejectsWrongOriginAndUnauthorized() throws {
        let (_, store, sock) = try startListener()
        let fd = try XCTUnwrap(ChromeTabsSocket.connect(sock))
        send(fd, .origin("chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"))
        send(fd, .hello(protocol: 1, extensionVersion: "1.0.0"))
        var b: UInt8 = 0
        XCTAssertEqual(read(fd, &b, 1), 0, "closed by the app")
        close(fd)
        let fd2 = try XCTUnwrap(ChromeTabsSocket.connect(sock))
        send(fd2, .hello(protocol: 1, extensionVersion: "1.0.0"))   // no origin first
        XCTAssertEqual(read(fd2, &b, 1), 0)
        close(fd2)
        XCTAssertTrue(store.isEmpty)

        let (_, store2, sock2) = try startListener(authorized: false)
        let fd3 = try XCTUnwrap(ChromeTabsSocket.connect(sock2))
        send(fd3, .origin(ChromeTabsConstants.allowedOrigins[0]))
        send(fd3, .hello(protocol: 1, extensionVersion: "1.0.0"))
        XCTAssertEqual(read(fd3, &b, 1), 0, "an unauthorised peer is closed at once")
        close(fd3)
        XCTAssertTrue(store2.isEmpty)
    }

    func testListenerOversizeFrameDropsConnection() throws {
        let (_, store, sock) = try startListener()
        let fd = try XCTUnwrap(ChromeTabsSocket.connect(sock))
        send(fd, .origin(ChromeTabsConstants.allowedOrigins[0]))
        send(fd, .hello(protocol: 1, extensionVersion: "1.0.0"))
        XCTAssertTrue(waitUntil { !store.hellos().isEmpty })
        var header = UInt32(64 * 1024 * 1024)
        _ = write(fd, &header, 4)
        var b: UInt8 = 0
        XCTAssertEqual(read(fd, &b, 1), 0)
        close(fd)
        XCTAssertTrue(waitUntil { store.isEmpty })
    }

    func testListenerStopClearsStoreAndSocket() throws {
        let (l, store, sock) = try startListener()
        let fd = try XCTUnwrap(ChromeTabsSocket.connect(sock))
        send(fd, .origin(ChromeTabsConstants.allowedOrigins[0]))
        send(fd, .hello(protocol: 1, extensionVersion: "1.0.0"))
        XCTAssertTrue(waitUntil { !store.isEmpty })
        l.stop()
        XCTAssertTrue(store.isEmpty)
        var st = stat()
        XCTAssertNotEqual(lstat(sock.path, &st), 0, "socket unlinked")
        var b: UInt8 = 0
        XCTAssertEqual(read(fd, &b, 1), 0, "open connections are closed")
        close(fd)
    }

    // MARK: The built binary as the native host

    var binary: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("FlightDeck") }

    /// A raw listening socket in `dir` (no checks: the test plays the app).
    func listenRaw(_ dir: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try XCTUnwrap(ChromeTabsSocket.address(dir.appendingPathComponent(ChromeTabsSocket.socketName).path))
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(r, 0); XCTAssertEqual(listen(fd, 1), 0)
        return fd
    }

    /// Chrome's side of the conversation, run against the built binary: it connects to the app's socket and names its
    /// origin, asks the extension for a refresh, relays the extension's frames, and exits 0 when stdin closes, with
    /// nothing on stdout but frames.
    func testChromeHostCLIEndToEnd() throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("FlightDeck binary not built at \(binary.path)") }
        let dir = tempDir()
        let lfd = try listenRaw(dir)
        defer { close(lfd) }
        let p = Process()
        p.executableURL = binary; p.arguments = [ChromeTabsConstants.allowedOrigins[0]]
        // The listener here is the test runner, not FlightDeck: a debug-only switch lets the host talk to it
        // (testChromeHostRefusesForeignListener covers the check itself).
        p.environment = ProcessInfo.processInfo.environment.merging(["FLIGHTDECK_CHROME_SOCKET_DIR": dir.path,
                                                                     "FLIGHTDECK_CHROME_TRUST_ANY_LISTENER": "1"]) { _, b in b }
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { p.terminate() } }

        var pfd = pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pfd, 1, 5000), 1, "the host connects")
        let conn = accept(lfd, nil, nil)
        XCTAssertGreaterThanOrEqual(conn, 0)
        defer { close(conn) }
        let fromHost: (Int) -> Data? = { ChromeFraming.readExact(fd: conn, count: $0) }
        XCTAssertEqual(try ChromeFraming.readFrame(fromHost).flatMap(ChromeTabsMessage.parse), .origin(ChromeTabsConstants.allowedOrigins[0]))

        let outFD = output.fileHandleForReading.fileDescriptor
        let stdoutFrame = try ChromeFraming.readFrame { ChromeFraming.readExact(fd: outFD, count: $0) }
        XCTAssertEqual(stdoutFrame.flatMap(ChromeTabsMessage.parse), .refresh)

        let hello = ChromeTabsMessage.hello(protocol: 1, extensionVersion: "1.0.0")
        input.fileHandleForWriting.write(ChromeFraming.encode(hello.encoded()))
        XCTAssertEqual(try ChromeFraming.readFrame(fromHost).flatMap(ChromeTabsMessage.parse), hello, "relayed to the app")
        // An invalid frame is relayed too, so the app drops that connection's previous table.
        let tabs = ChromeTabsMessage.tabs(table)
        let bad = Data(#"{"type":"tabs","seq":2,"tabs":[{"tabId":1.5}]}"#.utf8)
        input.fileHandleForWriting.write(ChromeFraming.encode(tabs.encoded()) + ChromeFraming.encode(bad))
        XCTAssertEqual(try ChromeFraming.readFrame(fromHost).flatMap(ChromeTabsMessage.parse), tabs)
        XCTAssertEqual(try ChromeFraming.readFrame(fromHost), bad)

        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile(), Data(), "nothing on stdout but frames")
    }

    /// A process that isn't FlightDeck binds the socket while the app isn't running: the host connects, checks the
    /// listener's signature, and hangs up without sending anything, not even its origin.
    func testChromeHostRefusesForeignListener() throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("FlightDeck binary not built at \(binary.path)") }
        let dir = tempDir()
        let lfd = try listenRaw(dir)
        defer { close(lfd) }
        let p = Process()
        p.executableURL = binary; p.arguments = [ChromeTabsConstants.allowedOrigins[0]]
        var env = ProcessInfo.processInfo.environment
        env["FLIGHTDECK_CHROME_SOCKET_DIR"] = dir.path; env["FLIGHTDECK_CHROME_TRUST_ANY_LISTENER"] = nil
        p.environment = env
        let input = Pipe()
        p.standardInput = input; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        var pfd = pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pfd, 1, 5000), 1, "the host connects")
        let conn = accept(lfd, nil, nil)
        XCTAssertGreaterThanOrEqual(conn, 0)
        defer { close(conn) }
        input.fileHandleForWriting.write(ChromeFraming.encode(ChromeTabsMessage.hello(protocol: 1, extensionVersion: "1.0.0").encoded()))
        var cfd = pollfd(fd: conn, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&cfd, 1, 5000), 1)
        var b: UInt8 = 0
        XCTAssertEqual(read(conn, &b, 1), 0, "closed with nothing sent")
    }

    func testChromeHostCLIRejectsUnknownOrigin() throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("FlightDeck binary not built at \(binary.path)") }
        let p = Process()
        p.executableURL = binary; p.arguments = ["chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"]
        let output = Pipe()
        p.standardInput = Pipe(); p.standardOutput = output; p.standardError = FileHandle.nullDevice
        let started = Date()
        let exited = expectation(description: "exits")
        p.terminationHandler = { _ in exited.fulfill() }
        try p.run()
        wait(for: [exited], timeout: 2)   // exiting before the GUI starts means no window
        if p.isRunning { p.terminate() }
        XCTAssertEqual(p.terminationStatus, 64)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile(), Data())
    }
}
