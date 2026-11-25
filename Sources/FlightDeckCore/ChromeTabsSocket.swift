import Foundation
import Darwin
import Security
// Chrome tabs: the Unix-domain socket between the native host (the app binary, launched by Chrome) and the running app.
// It lives in its own 0700 directory, because ~/Library/Application Support/Flightdeck is 0755. The app refuses to listen
// unless that directory is a real directory owned by the user with mode 0700, and only replaces a stale socket that is
// a socket owned by the user.
//
// Trust: the extension ID is public (anyone can load an unpacked extension with our key), so nothing the host says about
// itself is believed. A connecting process must run as this user and carry our own code signature (same Team ID, or for
// ad-hoc builds the same cdhash), and the browser is taken from the peer's parent process, which must be Google Chrome.

public enum ChromeTabsSocket {
    public enum SetupError: Error, Equatable {
        case notDirectory, symlink, wrongOwner, wrongMode(mode_t), staleNotSocket, staleWrongOwner, pathTooLong
    }
    public static let socketName = "chrome-tabs.sock"
    /// `sun_path` holds 104 bytes including the terminating NUL.
    static let maxPathBytes = 103

    /// The socket's location, computed the same way by the host and the app. `FLIGHTDECK_CHROME_SOCKET_DIR` overrides
    /// the directory (tests only). Otherwise appSupport/Flightdeck/ChromeTabs (the folder's existing spelling, see
    /// BlackBox.defaultDirectory), or a folder in the per-user temporary directory when that path is too long for a socket.
    public static func socketURL(appSupport: URL, tmpDir: String, env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let d = env["FLIGHTDECK_CHROME_SOCKET_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true).appendingPathComponent(socketName)
        }
        let dir = appSupport.appendingPathComponent("Flightdeck/ChromeTabs", isDirectory: true)
        let sock = dir.appendingPathComponent(socketName)
        if sock.path.utf8.count <= maxPathBytes { return sock }
        return URL(fileURLWithPath: tmpDir, isDirectory: true).appendingPathComponent("app.flightdeck.chrome-tabs", isDirectory: true)
            .appendingPathComponent(socketName)
    }

    public static func defaultSocketURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        let tmp = n > 0 ? String(cString: buf) : NSTemporaryDirectory()
        return socketURL(appSupport: appSupport, tmpDir: tmp)
    }

    /// Creates the directory 0700 if it is missing, then checks it: a real directory (not a symlink), ours, mode 0700.
    public static func prepareDirectory(_ dir: URL) throws {
        var st = stat()
        if lstat(dir.path, &st) != 0 {
            try? FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mkdir(dir.path, 0o700) != 0 && errno != EEXIST { throw SetupError.notDirectory }
            guard lstat(dir.path, &st) == 0 else { throw SetupError.notDirectory }
        }
        if st.st_mode & S_IFMT == S_IFLNK { throw SetupError.symlink }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw SetupError.notDirectory }
        guard st.st_uid == getuid() else { throw SetupError.wrongOwner }
        guard st.st_mode & 0o777 == 0o700 else { throw SetupError.wrongMode(st.st_mode & 0o777) }
    }

    /// Removes a socket left by an earlier run. Nothing there is fine; anything that isn't our own socket is an error.
    public static func removeStaleSocket(_ sock: URL) throws {
        var st = stat()
        guard lstat(sock.path, &st) == 0 else {
            if errno == ENOENT { return }
            throw SetupError.staleNotSocket
        }
        guard st.st_mode & S_IFMT == S_IFSOCK else { throw SetupError.staleNotSocket }
        guard st.st_uid == getuid() else { throw SetupError.staleWrongOwner }
        unlink(sock.path)
    }

    /// A `sockaddr_un` for `path`, or nil when it doesn't fit.
    static func address(_ path: String) -> sockaddr_un? {
        guard path.utf8.count <= maxPathBytes else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.utf8.enumerated() { raw[i] = b }
            raw[path.utf8.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connects to the app's socket (the host side). nil when nothing is listening.
    public static func connect(_ sock: URL) -> Int32? {
        guard var addr = address(sock.path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        noSigPipe(fd)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if r != 0 { close(fd); return nil }
        return fd
    }
}

/// Who is on the other end of an accepted connection, as the kernel reports it.
public struct ChromePeer: Sendable, Equatable {
    public var pid: pid_t
    public var uid: uid_t
    public var auditToken: audit_token_t?
    public init(pid: pid_t, uid: uid_t, auditToken: audit_token_t?) { self.pid = pid; self.uid = uid; self.auditToken = auditToken }
    public static func == (a: ChromePeer, b: ChromePeer) -> Bool {
        a.pid == b.pid && a.uid == b.uid && a.auditToken.map(Self.bytes) == b.auditToken.map(Self.bytes)
    }
    static func bytes(_ t: audit_token_t) -> [UInt32] { withUnsafeBytes(of: t) { Array($0.bindMemory(to: UInt32.self)) } }
}

public enum ChromePeerAuth {
    // <sys/un.h>: socket options at level SOL_LOCAL.
    static let solLocal: Int32 = 0, localPeerPID: Int32 = 0x002, localPeerToken: Int32 = 0x006

    /// getpeereid plus LOCAL_PEERPID and LOCAL_PEERTOKEN (the audit token, which names the exact process even if its pid
    /// is reused). nil when the kernel won't say.
    public static func peer(of fd: Int32) -> ChromePeer? {
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        var pid = pid_t(0)
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, solLocal, localPeerPID, &pid, &len) == 0 else { return nil }
        var token = audit_token_t()
        var tlen = socklen_t(MemoryLayout<audit_token_t>.size)
        let hasToken = getsockopt(fd, solLocal, localPeerToken, &token, &tlen) == 0
        return ChromePeer(pid: pid, uid: uid, auditToken: hasToken ? token : nil)
    }

    /// The requirement a host must meet: our Team ID for a Developer ID build, otherwise our exact cdhash (the same
    /// binary, since the host is this executable). nil when we are unsigned.
    public static func ownRequirement() -> SecRequirement? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var st: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &st) == errSecSuccess, let st else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(st, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        let text: String
        if let team = d[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) {
            text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        } else if let cdhash = d[kSecCodeInfoUnique as String] as? Data, !cdhash.isEmpty {
            text = "cdhash H\"\(cdhash.map { String(format: "%02x", $0) }.joined())\""
        } else {
            return nil
        }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess else { return nil }
        return req
    }

    /// Checks the running peer process (by audit token) against `requirement`.
    public static func isTrusted(_ peer: ChromePeer, requirement: SecRequirement) -> Bool {
        guard peer.uid == getuid(), let token = peer.auditToken else { return false }
        let attrs = [kSecGuestAttributeAudit: withUnsafeBytes(of: token) { Data($0) }] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static let chromeSuffix = "Google Chrome.app/Contents/MacOS/Google Chrome"

    /// The browser process that launched the host: the host's parent, accepted only when its executable is Google
    /// Chrome (stable). Returns its pid and start time, so a later process reusing the pid never matches.
    public static func browser(ofHostPID pid: pid_t) -> ProcessIdentity? {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        let ppid = pid_t(bsd.pbi_ppid)
        guard ppid > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(ppid, &buf, UInt32(buf.count)) > 0, String(cString: buf).hasSuffix(chromeSuffix) else { return nil }
        return ProcessSampler.identity(of: ppid)
    }

    /// The production check for an accepted connection: our user, our signature, launched by Google Chrome.
    public static func authorize(fd: Int32, requirement: SecRequirement?) -> ProcessIdentity? {
        guard let requirement, let peer = peer(of: fd), isTrusted(peer, requirement: requirement) else { return nil }
        return browser(ofHostPID: peer.pid)
    }
}
