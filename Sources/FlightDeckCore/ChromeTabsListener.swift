import Foundation
import Darwin
import os
// Chrome tabs: the app's end of the host socket. Each accepted connection is one native host, so one Chrome profile.
// Per connection:
//   1. `authorize` (our user, our code signature, parent is Google Chrome) gives the browser identity, or the
//      connection is closed.
//   2. The first frame must be `origin` with an allowed extension origin, or the connection is closed.
//   3. Then `hello` and `tabs` go to the store. A frame that fails validation drops that connection's table; a frame
//      over the size cap closes the connection.
//   4. On end of input, that connection's table and hello are removed.
// Diagnostics log counts and error kinds only, never message content.

public final class ChromeTabsListener: @unchecked Sendable {
    private let socketURL: URL
    private let store: ChromeTabStore
    private let authorize: (Int32) -> ProcessIdentity?
    private let log = Logger(subsystem: "app.flightdeck", category: "chrome-tabs")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var connections: [UInt64: Int32] = [:]
    private var nextConnection: UInt64 = 1
    private let acceptQueue = DispatchQueue(label: "flightdeck.chrome-tabs.accept")
    /// Fired after any store change (for the Settings status). Called on a background queue.
    public var onChange: (@Sendable () -> Void)?

    /// `authorize` returns the browser identity for an accepted connection, or nil to close it.
    public init(socket: URL, store: ChromeTabStore, authorize: @escaping (Int32) -> ProcessIdentity?) {
        self.socketURL = socket; self.store = store; self.authorize = authorize
    }

    public func start() throws {
        try ChromeTabsSocket.prepareDirectory(socketURL.deletingLastPathComponent())
        try ChromeTabsSocket.removeStaleSocket(socketURL)
        guard var addr = ChromeTabsSocket.address(socketURL.path) else { throw ChromeTabsSocket.SetupError.pathTooLong }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let e = errno; close(fd); throw POSIXError(.init(rawValue: e) ?? .EIO) }
        chmod(socketURL.path, 0o600)
        guard listen(fd, 8) == 0 else { let e = errno; close(fd); unlink(socketURL.path); throw POSIXError(.init(rawValue: e) ?? .EIO) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptPending(fd) }
        src.setCancelHandler { close(fd) }
        lock.lock(); listenFD = fd; source = src; lock.unlock()
        src.resume()
    }

    /// Closes the listener and every connection, removes the socket and clears the store.
    public func stop() {
        // shutdown runs under the lock: `serve` closes its fd under the same lock, so a number the kernel has already
        // handed to another socket (say an MCP connection) is never shut down here.
        lock.lock()
        let src = source, had = listenFD >= 0
        for fd in connections.values { shutdown(fd, SHUT_RDWR) }   // wakes each reader, which then closes its fd
        source = nil; listenFD = -1; connections.removeAll()
        lock.unlock()
        src?.cancel()
        if had { unlink(socketURL.path) }
        store.removeAll()
        onChange?()
    }

    private func acceptPending(_ lfd: Int32) {
        while true {
            let fd = accept(lfd, nil, nil)
            guard fd >= 0 else { return }   // EAGAIN: nothing more waiting
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            ChromeTabsSocket.noSigPipe(fd)
            guard let browser = authorize(fd) else {
                log.notice("refused a connection that isn't a FlightDeck host launched by Chrome")
                close(fd); continue
            }
            lock.lock()
            guard listenFD >= 0 else { lock.unlock(); close(fd); return }
            let id = nextConnection; nextConnection += 1
            connections[id] = fd
            lock.unlock()
            let key = ChromeTabStore.Key(browser: browser, connection: id)
            DispatchQueue(label: "flightdeck.chrome-tabs.conn").async { [weak self] in self?.serve(fd, key) }
        }
    }

    private func serve(_ fd: Int32, _ key: ChromeTabStore.Key) {
        defer {
            store.remove(key)
            lock.lock(); connections[key.connection] = nil; close(fd); lock.unlock()   // together: see stop()
            onChange?()
        }
        let read: (Int) -> Data? = { ChromeFraming.readExact(fd: fd, count: $0) }
        do {
            guard let first = try ChromeFraming.readFrame(read), case .origin(let o)? = ChromeTabsMessage.parse(first),
                  ChromeTabsConstants.allowedOrigins.contains(o) else {
                log.notice("closed a host connection without an allowed origin")
                return
            }
            while let frame = try ChromeFraming.readFrame(read) {
                switch ChromeTabsMessage.parse(frame) {
                case .hello(let p, let v)?: store.setHello(.init(protocolVersion: p, extensionVersion: v), for: key)
                case .tabs(let t)?: store.setTable(t, for: key)
                case nil:
                    log.notice("dropped an invalid message of \(frame.count, privacy: .public) bytes")
                    store.invalidate(key)
                default: continue
                }
                onChange?()
            }
        } catch {
            log.notice("closed a host connection that sent an oversized frame")
        }
    }
}
