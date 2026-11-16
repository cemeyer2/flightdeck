import Foundation
import Darwin

public struct ConnectionItem: Identifiable, Hashable, Sendable {
    public var id: String { "\(pid)-\(proto)-\(local)-\(remote)" }
    public var pid: Int32
    public var process: String
    public var proto: String
    public var local: String
    public var remote: String
    public var state: String
}

public struct UserSession: Identifiable, Hashable, Sendable {
    public var id: String { user + tty }
    public var user: String
    public var tty: String
    public var host: String
    public var loginTime: Date
}

public enum Connections {
    /// Parses `lsof -F` output. Only the current user's processes are visible without root.
    public static func list() -> [ConnectionItem] {
        guard let out = Shell.run("/usr/sbin/lsof", ["-nP", "-i", "-FpcPnT"], timeout: 15) else { return [] }
        var items: [ConnectionItem] = []
        var pid: Int32 = 0, cmd = "", proto = "", name = "", state = ""
        func flush() {
            guard !name.isEmpty else { return }
            let parts = name.components(separatedBy: "->")
            items.append(ConnectionItem(pid: pid, process: cmd, proto: proto, local: parts[0],
                                        remote: parts.count > 1 ? parts[1] : "", state: state.isEmpty ? (proto == "UDP" ? "—" : "") : state))
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
            case "T": if v.hasPrefix("ST=") { state = String(v.dropFirst(3)) }
            default: break
            }
        }
        flush()
        return items
    }

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
