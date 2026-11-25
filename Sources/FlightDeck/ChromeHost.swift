// Chrome tabs: the app binary as Chrome's native-messaging host. Chrome launches it with the extension's origin as the
// only argument (see ChromeHostArgv) and talks framed JSON over stdin/stdout. This mode is a thin relay: frames from
// the extension go to the running app over the private socket (ChromeTabsSocket) once the host has checked that the
// listener carries our own signature, and when the app connects the host asks the extension to send its table again.
// stdout carries framed messages only; stderr, which Chrome may save to its log, carries event kinds and byte counts,
// never message content.
import Foundation
import FlightDeckCore

enum ChromeHost {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var socketFD: Int32 = -1
    // Only the latest of each is kept and re-sent on (re)connect, never a backlog.
    nonisolated(unsafe) private static var latestHello: Data?
    nonisolated(unsafe) private static var latestTabs: Data?

    static func run(origin: String?) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        signal(SIGPIPE, SIG_IGN)
        let origin = origin ?? ChromeTabsConstants.allowedOrigins[0]
        let reader = Thread { readExtension() }
        reader.start()
        let sock = ChromeTabsSocket.defaultSocketURL()
        let requirement = ChromePeerAuth.ownRequirement()
        while true {
            guard let fd = ChromeTabsSocket.connect(sock) else { sleep(5); continue }
            // Nothing is sent (not even the origin) until the listener is known to be FlightDeck itself.
            guard trustsAnyListener || ChromePeerAuth.isTrustedListener(fd: fd, requirement: requirement) else {
                log("refused a socket listener that isn't FlightDeck")
                close(fd); sleep(5); continue
            }
            lock.lock()
            var ok = ChromeFraming.writeFrame(fd: fd, ChromeTabsMessage.origin(origin).encoded())
            for m in [latestHello, latestTabs].compactMap({ $0 }) where ok { ok = ChromeFraming.writeFrame(fd: fd, m) }
            if ok { socketFD = fd }
            lock.unlock()
            if ok {
                log("connected to FlightDeck")
                _ = ChromeFraming.writeFrame(fd: 1, ChromeTabsMessage.refresh.encoded())
                // The app never sends anything; this read returns when it closes the connection (or quits).
                var b: UInt8 = 0
                while read(fd, &b, 1) > 0 {}
                log("FlightDeck closed the connection")
            }
            lock.lock(); socketFD = -1; lock.unlock()
            close(fd)
            sleep(5)
        }
    }

    /// Reads the extension's frames from stdin until Chrome closes it, forwarding each one to the app.
    private static func readExtension() {
        let read: (Int) -> Data? = { ChromeFraming.readExact(fd: 0, count: $0) }
        while true {
            let frame: Data
            do {
                guard let f = try ChromeFraming.readFrame(read) else { log("extension disconnected"); exit(0) }
                frame = f
            } catch {
                log("refused an oversized frame"); exit(65)
            }
            // Every frame is forwarded, valid or not: the app validates it, and an invalid one makes it drop that
            // connection's previous table. This check only decides what to keep for a reconnect.
            lock.lock()
            switch ChromeTabsMessage.parse(frame) {
            case .hello?: latestHello = frame
            case .tabs?: latestTabs = frame
            case nil: latestTabs = nil; log("forwarding an invalid message of \(frame.count) bytes")
            default: break
            }
            if socketFD >= 0 && !ChromeFraming.writeFrame(fd: socketFD, frame) {
                shutdown(socketFD, SHUT_RDWR)   // the connection loop sees the close and retries
            }
            lock.unlock()
        }
    }

    /// Debug builds only, for the end-to-end test whose listener is the test runner rather than FlightDeck. Release
    /// builds (the app bundle) always check the listener.
    private static var trustsAnyListener: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["FLIGHTDECK_CHROME_TRUST_ANY_LISTENER"] == "1"
        #else
        return false
        #endif
    }

    private static func log(_ s: String) { FileHandle.standardError.write(Data("FlightDeck Chrome host: \(s)\n".utf8)) }
}
