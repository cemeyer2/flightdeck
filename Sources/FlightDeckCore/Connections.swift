import Foundation
import Darwin

// The Connections tool: open internet sockets per process via lsof, and logged-in user sessions from utmpx. Both are
// loaded on demand by the UI (not per tick), since lsof can take seconds.
/// One open internet socket. `local`/`remote` are lsof's numeric "host:port" strings; `remote` is "" when unconnected.
/// `state` is the TCP state (ESTABLISHED, LISTEN, ...), "—" for UDP (stateless).
public struct ConnectionItem: Identifiable, Hashable, Sendable {
    public var id: String { "\(pid)-\(proto)-\(local)-\(remote)" + (occurrence > 1 ? "#\(occurrence)" : "") }
    /// 1 for the first socket with this pid/proto/local/remote, 2… for identical ones (e.g. several unconnected UDP
    /// sockets), so SwiftUI lists get unique, stable IDs.
    public var occurrence = 1
    public var pid: Int32
    public var process: String
    public var proto: String
    public var local: String
    public var remote: String
    public var state: String
}

/// One login session (Terminal tty, SSH, console) from the utmpx database, as shown by `who`.
public struct UserSession: Identifiable, Hashable, Sendable {
    public var id: String { user + tty }
    public var user: String
    public var tty: String
    public var host: String
    public var loginTime: Date
}

public enum Connections {
    /// Parses `lsof -F` output. Only the current user's processes are visible without root.
    /// lsof is used because libproc only enumerates sockets one process at a time and needs per-process access, whereas
    /// lsof does the whole walk in one call. -n/-P skip DNS and port-name lookups; -F emits machine-readable field lines
    /// (p pid, c command, f fd, P protocol, n name, T TCP info). Returns [] if lsof can't run.
    public static func list() -> [ConnectionItem] {
        guard let out = Shell.run("/usr/sbin/lsof", ["-nP", "-i", "-FpcPnT"], timeout: 15) else { return [] }
        return parse(out)
    }

    /// Parses `lsof -nP -i -FpcPnT` output (the app's own run, or the root helper's).
    static func parse(_ out: String) -> [ConnectionItem] {
        var items: [ConnectionItem] = []
        var pid: Int32 = 0, cmd = "", proto = "", name = "", state = ""
        var seen: [String: Int] = [:]
        // Fields arrive as a stream: a "p" line starts a process, an "f" line starts each of its files, and the following lines
        // describe that file. A pending socket is therefore emitted whenever the next file or process begins (and at the end).
        func flush() {
            guard !name.isEmpty else { return }
            let parts = name.components(separatedBy: "->")
            var item = ConnectionItem(pid: pid, process: cmd, proto: proto, local: parts[0],
                                      remote: parts.count > 1 ? parts[1] : "", state: state.isEmpty ? (proto == "UDP" ? "—" : "") : state)
            seen[item.id, default: 0] += 1
            item.occurrence = seen[item.id]!
            items.append(item)
            name = ""; state = ""
        }
        for line in out.split(separator: "\n") {
            guard let f = line.first else { continue }
            let v = String(line.dropFirst())
            switch f {
            case "p": flush(); pid = Int32(v) ?? 0
            case "c": cmd = v
            case "f": flush()
            case "P": proto = v
            case "n": name = v
            // T lines carry several TCP/TPI values (ST=state, QR=/QS= queue sizes); only the state is kept.
            case "T": if v.hasPrefix("ST=") { state = String(v.dropFirst(3)) }
            default: break
            }
        }
        flush()
        return items
    }

    /// USER_PROCESS entries from utmpx. The fixed-size C char arrays are read up to their first NUL.
    public static func sessions() -> [UserSession] {
        var out: [UserSession] = []
        setutxent()
        while let e = getutxent() {
            guard e.pointee.ut_type == USER_PROCESS else { continue }
            func s<T>(_ t: T) -> String { withUnsafeBytes(of: t) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) } }
            out.append(UserSession(user: s(e.pointee.ut_user), tty: s(e.pointee.ut_line), host: s(e.pointee.ut_host),
                                   loginTime: Date(timeIntervalSince1970: TimeInterval(e.pointee.ut_tv.tv_sec))))
        }
        endutxent()
        return out
    }
}
