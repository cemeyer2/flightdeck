import Foundation
import Darwin

// The Developer destination's "Dev servers" list: TCP listeners owned by this user's processes that `DevClassifier`
// recognises as developer tools, with each process's project folder (its working directory) and command line.
// CPU, memory and uptime are not measured here: the UI joins them from the live process sample by identity.

/// One dev-tool process and the TCP ports it listens on.
public struct DevServer: Identifiable, Sendable {
    public var id: ProcessIdentity { identity }
    public var identity: ProcessIdentity
    public var kind: DevToolKind
    /// Process name as netstat/lsof reported it.
    public var process: String
    /// Full executable path ("" if unknown).
    public var executable: String
    public var arguments: [String]
    /// Listening TCP ports, lowest first, and the address of the first (to tell loopback-only from network-wide).
    public var ports: [Int]
    public var address: String
    public var exposure: ListeningSocket.Exposure
    /// The process's current working directory: for a dev server, normally the project it was started in.
    public var projectFolder: Measured<String>
    public var startDate: Date { Date(timeIntervalSince1970: Double(identity.startTime) / 1e6) }

    public init(identity: ProcessIdentity, kind: DevToolKind, process: String, executable: String, arguments: [String],
                ports: [Int], address: String, projectFolder: Measured<String>) {
        self.identity = identity; self.kind = kind; self.process = process; self.executable = executable
        self.arguments = arguments; self.ports = ports; self.address = address
        self.exposure = ListeningSocket.exposure(of: address); self.projectFolder = projectFolder
    }

    /// The URL to open for a port. Always localhost: a server bound to one LAN address only would need that address,
    /// so `browserHost` returns it in that case.
    public func url(port: Int) -> URL? { URL(string: "http://\(browserHost):\(port)") }
    var browserHost: String {
        if exposure == .oneInterface { return address.contains(":") ? "[\(address)]" : address }
        return address.contains(":") && exposure == .loopback ? "[::1]" : "localhost"
    }
}

/// The outcome of one dev-server scan.
public struct DevServerScan: Sendable {
    public var servers: [DevServer]
    /// Listening processes of this user that aren't recognised dev tools (shown as a count, so nothing is hidden silently).
    public var otherOwnListeners: [String]
    public var coverage: ListeningScan.Coverage
    public var time: Date
    public init(servers: [DevServer], otherOwnListeners: [String], coverage: ListeningScan.Coverage, time: Date = Date()) {
        self.servers = servers; self.otherOwnListeners = otherOwnListeners; self.coverage = coverage; self.time = time
    }
}

public enum DevServers {
    /// Scans listening sockets and keeps this user's recognised dev tools. Blocking (netstat ~100 ms plus a few
    /// syscalls per listener); call off the main thread. UDP is ignored: dev servers listen on TCP.
    public static func scan() -> DevServerScan {
        let s = ListeningPorts.scan()
        return build(from: s, isOwn: DevShell.isOwn, identity: ProcessSampler.identity(of:),
                     executable: DevShell.executable(of:), arguments: DevShell.arguments(of:), cwd: DevShell.workingDirectory(of:))
    }

    /// Groups sockets by process and classifies each. The process lookups are injected so tests can drive this with
    /// synthetic sockets and processes.
    static func build(from s: ListeningScan, isOwn: (Int32) -> Bool, identity: (Int32) -> ProcessIdentity?,
                      executable: (Int32) -> String, arguments: (Int32) -> [String]?, cwd: (Int32) -> Measured<String>) -> DevServerScan {
        let tcp = s.sockets.filter { $0.proto == "TCP" && isOwn($0.pid) }
        let byPID = Dictionary(grouping: tcp, by: \.pid)
        var servers: [DevServer] = [], others: [String] = []
        for (pid, socks) in byPID {
            guard let ident = identity(pid) else { continue }   // exited since the scan
            let exe = executable(pid)
            let args = arguments(pid) ?? []
            let name = socks[0].process
            guard let kind = DevClassifier.server(executable: exe.isEmpty ? name : exe, args: args) else {
                others.append(name); continue
            }
            // The most exposed socket decides the address shown (a server on 0.0.0.0 and ::1 is reachable from the network).
            let ordered = socks.sorted { ($0.exposure, $0.port) < ($1.exposure, $1.port) }
            servers.append(DevServer(identity: ident, kind: kind, process: name, executable: exe, arguments: args,
                                     ports: Array(Set(socks.map(\.port))).sorted(), address: ordered[0].address, projectFolder: cwd(pid)))
        }
        servers.sort { ($0.ports.first ?? 0, $0.identity.pid) < ($1.ports.first ?? 0, $1.identity.pid) }
        return DevServerScan(servers: servers, otherOwnListeners: Array(Set(others)).sorted(), coverage: s.coverage)
    }

    /// Everything listening on `port` (all users' processes when netstat shows owners), for the port finder.
    public static func find(port: Int, in s: ListeningScan) -> [ListeningSocket] { s.sockets.filter { $0.port == port } }

    /// Parses the port finder's text field: a plain port number 1-65535, also accepting "localhost:3000", ":3000" or a
    /// URL with an explicit port. nil for anything else.
    public static func parsePort(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return (1...65535).contains(n) ? n : nil }
        if let u = URL(string: t), let p = u.port, u.scheme != nil { return (1...65535).contains(p) ? p : nil }
        if let colon = t.lastIndex(of: ":"), let n = Int(t[t.index(after: colon)...]) { return (1...65535).contains(n) ? n : nil }
        return nil
    }
}
