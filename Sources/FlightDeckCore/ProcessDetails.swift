import Foundation
import Darwin
import Security

// Slow, on-demand process details for the inspector (InspectorView refreshes them on a detached utility task), plus
// stack sampling via /usr/bin/sample and the nice-value action. Unlike ProcessSampler this is never run per tick.
/// Everything the inspector shows about one process beyond the per-sample numbers. Fields that can't be
/// read (other users' processes without root, hardened processes) are `.unavailable`, never empty-but-OK.
public struct ProcessDetails: Sendable {
    /// One file descriptor from PROC_PIDLISTFDS, with a human description (vnode path, socket summary, or fd type).
    public struct OpenFile: Sendable, Hashable, Identifiable, Codable {
        public enum Kind: String, Sendable, Codable { case file = "File", socket = "Socket", pipe = "Pipe", kqueue = "KQueue", other = "Other" }
        public var id: Int32 { fd }
        public var fd: Int32
        public var kind: Kind
        public var description: String
    }
    /// A decoded socket fd (PROC_PIDFDSOCKETINFO). Addresses are "host:port" ("*" for an unbound port, IPv6 bracketed);
    /// `remote` is "" for listening/unconnected sockets and `state` is "" for non-TCP sockets.
    public struct Socket: Sendable, Hashable, Identifiable {
        public var id: Int32 { fd }
        public var fd: Int32
        public var proto: String          // TCP, UDP, Unix
        public var local: String
        public var remote: String
        public var state: String
    }
    /// One thread from PROC_PIDTHREADINFO. `id` is the kernel thread handle; times are cumulative seconds.
    public struct ThreadInfo: Sendable, Hashable, Identifiable, Codable {
        public var id: UInt64
        public var name: String
        public var cpu: Double            // % of one core (kernel's decayed estimate)
        public var state: String
        public var priority: Int32
        public var userTime: Double, systemTime: Double
    }
    /// Code-signing facts for the executable (or its enclosing .app bundle), from Security.framework's static code APIs.
    public struct Signature: Sendable, Hashable {
        public var identifier: String?
        public var teamID: String?
        public var authority: [String]
        public var isApple: Bool
        public var valid: Bool
        public var hardenedRuntime: Bool
        /// One-line description for the inspector. With no certificate chain and no team ID the signature is ad-hoc.
        public var summary: String {
            if !valid { return "Not signed or signature invalid" }
            if isApple { return "Signed by Apple" }
            return authority.first.map { "Signed: \($0)" } ?? (teamID.map { "Signed (team \($0))" } ?? "Ad-hoc signed")
        }
    }

    /// Cumulative kernel counters (Activity Monitor's "Statistics"); rates come from two readings.
    public struct Counters: Sendable, Hashable {
        public var time: Date
        public var faults: Int64, pageins: Int64, cowFaults: Int64
        public var machMessagesSent: Int64, machMessagesReceived: Int64
        public var machSyscalls: Int64, unixSyscalls: Int64, contextSwitches: Int64
        public var runningThreads: Int32, priority: Int32
        public var residentBytes: UInt64, virtualBytes: UInt64
        public var peakFootprint: UInt64?, instructions: UInt64?, cycles: UInt64?, logicalWrites: UInt64?
        public var interruptWakeups: UInt64?, idleWakeups: UInt64?
    }

    // Measured fields are `.unavailable(reason)` when the kernel refuses the query; `sockets` is simply empty in that case
    // because it is derived from the same fd list as `files`. `signature` is nil when the executable path is unknown or
    // unreadable; `nice` is nil if getpriority failed; `counters` is nil without task-info access.
    public var arguments: Measured<[String]>
    public var environment: Measured<[String]>
    public var cwd: Measured<String>
    public var files: Measured<[OpenFile]>
    public var sockets: [Socket]
    public var threads: Measured<[ThreadInfo]>
    public var signature: Signature?
    public var nice: Int32?
    public var ancestry: [(pid: Int32, name: String)]
    public var counters: Counters?
}

/// Stateless readers behind ProcessDetails. All are synchronous and some are slow (signature checks, `sample`), so
/// callers run them off the main actor.
public enum ProcessInspector {
    /// Gathers everything for one process. `path` comes from the ProcessSample (empty skips the signature check).
    public static func details(pid: Int32, path: String) -> ProcessDetails {
        let (args, env) = argsAndEnv(pid)
        let (files, sockets) = openFiles(pid)
        // getpriority can legitimately return -1, so success is detected by clearing errno beforehand.
        errno = 0
        let n = getpriority(PRIO_PROCESS, id_t(pid))
        let niceOK = errno == 0   // read now: later calls overwrite errno
        return ProcessDetails(arguments: args, environment: env, cwd: cwd(pid), files: files, sockets: sockets,
                              threads: threads(pid), signature: path.isEmpty ? nil : signature(path),
                              nice: niceOK ? n : nil, ancestry: ancestry(pid), counters: counters(pid))
    }

    /// Arguments and environment from the KERN_PROCARGS2 sysctl. Only readable for the user's own processes (EINVAL
    /// otherwise, reported as "not permitted"); the environment may be truncated by the kernel's buffer limit.
    static func argsAndEnv(_ pid: Int32) -> (Measured<[String]>, Measured<[String]>) {
        // Buffer layout: Int32 argc, then the exec path (NUL-terminated), NUL padding to alignment, then argc argv strings
        // followed by the envp strings, each NUL-terminated. The first sysctl call only reports the needed size.
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return (.unavailable("not permitted"), .unavailable("not permitted")) }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return (.unavailable("not permitted"), .unavailable("not permitted")) }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }        // exec path
        while i < size && buf[i] == 0 { i += 1 }        // padding
        var strings: [String] = []
        var start = i
        // Empty strings are skipped. A run of NULs after the argv strings marks the end of the useful area (after envp
        // the kernel may leave padding and the "apple" strings), hence the break once argc strings have been read.
        while i < size {
            if buf[i] == 0 {
                if i > start { strings.append(String(decoding: buf[start..<i], as: UTF8.self)) } else if strings.count >= argc { break }
                start = i + 1
            }
            i += 1
        }
        let args = Array(strings.prefix(argc))
        let env = strings.count > argc ? Array(strings[argc...]) : []
        return (.value(args), .value(env))
    }

    /// Cumulative kernel counters for the Statistics panel, read via PROC_PIDTASKINFO (fails for other users' processes
    /// without root, hence nil) plus rusage v6 for the optional extras. Instructions and cycles are nil when rusage reports
    /// 0, which happens on hardware/VMs without per-process PMC accounting. Rates are derived by the UI from two readings
    /// using `time`.
    public static func counters(_ pid: Int32) -> ProcessDetails.Counters? {
        var ti = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size) else { return nil }
        var ru = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &ru) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) } } == 0
        return .init(time: Date(), faults: Int64(ti.pti_faults), pageins: Int64(ti.pti_pageins), cowFaults: Int64(ti.pti_cow_faults),
                     machMessagesSent: Int64(ti.pti_messages_sent), machMessagesReceived: Int64(ti.pti_messages_received),
                     machSyscalls: Int64(ti.pti_syscalls_mach), unixSyscalls: Int64(ti.pti_syscalls_unix), contextSwitches: Int64(ti.pti_csw),
                     runningThreads: ti.pti_numrunning, priority: ti.pti_priority, residentBytes: ti.pti_resident_size, virtualBytes: ti.pti_virtual_size,
                     peakFootprint: ok ? ru.ri_lifetime_max_phys_footprint : nil, instructions: ok && ru.ri_instructions > 0 ? ru.ri_instructions : nil,
                     cycles: ok && ru.ri_cycles > 0 ? ru.ri_cycles : nil, logicalWrites: ok ? ru.ri_logical_writes : nil,
                     interruptWakeups: ok ? ru.ri_interrupt_wkups : nil, idleWakeups: ok ? ru.ri_pkg_idle_wkups : nil)
    }

    /// Current working directory via PROC_PIDVNODEPATHINFO. `vip_path` is a fixed MAXPATHLEN C char tuple, so it is read
    /// as raw bytes up to the NUL.
    static func cwd(_ pid: Int32) -> Measured<String> {
        var info = proc_vnodepathinfo()
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard r == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return .unavailable("not permitted") }
        return .value(withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) })
    }

    /// Lists file descriptors (PROC_PIDLISTFDS) and describes each by type. Same-user processes only without root.
    static func openFiles(_ pid: Int32) -> (Measured<[ProcessDetails.OpenFile]>, [ProcessDetails.Socket]) {
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return (.unavailable("not permitted"), []) }
        // The first call returns the byte size needed; 16 spare slots cover fds opened before the second call. The second
        // call returns bytes actually written, which bounds the loop below.
        let count = Int(need) / MemoryLayout<proc_fdinfo>.size + 16
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(count * MemoryLayout<proc_fdinfo>.size))
        guard got > 0 else { return (.unavailable("not permitted"), []) }
        var files: [ProcessDetails.OpenFile] = []
        var sockets: [ProcessDetails.Socket] = []
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) {
            switch Int32(fd.proc_fdtype) {
            case PROX_FDTYPE_VNODE:
                var v = vnode_fdinfowithpath()
                let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &v, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
                let path = r > 0 ? withUnsafeBytes(of: v.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } : "?"
                files.append(.init(fd: fd.proc_fd, kind: .file, description: path))
            case PROX_FDTYPE_SOCKET:
                var si = socket_fdinfo()
                let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size))
                if r > 0, let s = describe(si, fd: fd.proc_fd) {
                    sockets.append(s)
                    files.append(.init(fd: fd.proc_fd, kind: .socket, description: "\(s.proto) \(s.local)\(s.remote.isEmpty ? "" : " → \(s.remote)") \(s.state)"))
                } else { files.append(.init(fd: fd.proc_fd, kind: .socket, description: "socket")) }
            case PROX_FDTYPE_PIPE: files.append(.init(fd: fd.proc_fd, kind: .pipe, description: "pipe"))
            case PROX_FDTYPE_KQUEUE: files.append(.init(fd: fd.proc_fd, kind: .kqueue, description: "kqueue"))
            // Remaining PROX_FDTYPE_* values from <sys/proc_info.h> (not all are imported into Swift):
            // 4 PSHM, 5 PSEM, 8 FSEVENTS, 9 NETPOLICY, 10 CHANNEL, 11 NEXUS.
            default:
                let names: [UInt32: String] = [4: "POSIX shared memory", 5: "POSIX semaphore", 8: "FSEvents", 9: "network policy", 10: "Skywalk channel", 11: "Skywalk nexus"]
                files.append(.init(fd: fd.proc_fd, kind: .other, description: names[fd.proc_fdtype] ?? "type \(fd.proc_fdtype)"))
            }
        }
        return (.value(files), sockets)
    }

    /// TCP state names indexed by tcpsi_state (TCPS_* values 0...10 from <netinet/tcp_fsm.h>).
    static let tcpStates = ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RECEIVED", "ESTABLISHED", "CLOSE_WAIT", "FIN_WAIT_1",
                            "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT"]

    /// Decodes socket_fdinfo into a Socket for TCP, UDP/raw IP and Unix-domain sockets; nil for other kinds
    /// (e.g. kernel control, system sockets), which the caller shows as a plain "socket".
    static func describe(_ si: socket_fdinfo, fd: Int32) -> ProcessDetails.Socket? {
        let s = si.psi
        func addr(_ i: in_sockinfo, local: Bool) -> String {
            // Ports are stored as Int32 fields holding the 16-bit value in network byte order: truncate, then byte-swap.
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: local ? i.insi_lport : i.insi_fport)))
            var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if i.insi_vflag & UInt8(INI_IPV4) != 0 {
                var a = local ? i.insi_laddr.ina_46.i46a_addr4 : i.insi_faddr.ina_46.i46a_addr4
                inet_ntop(AF_INET, &a, &out, socklen_t(out.count))
            } else {
                var a = local ? i.insi_laddr.ina_6 : i.insi_faddr.ina_6
                inet_ntop(AF_INET6, &a, &out, socklen_t(out.count))
            }
            let host = String(cString: out)
            // An all-zero peer means "not connected", which is shown as no remote at all.
            if !local && port == 0 && (host == "0.0.0.0" || host == "::") { return "" }
            return (host.contains(":") ? "[\(host)]" : host) + ":" + (port == 0 ? "*" : "\(port)")
        }
        // soi_proto is a C union; soi_kind says which member is valid.
        switch Int(s.soi_kind) {
        case Int(SOCKINFO_TCP):
            let t = s.soi_proto.pri_tcp
            let st = Int(t.tcpsi_state)
            return .init(fd: fd, proto: "TCP", local: addr(t.tcpsi_ini, local: true), remote: addr(t.tcpsi_ini, local: false),
                         state: st < tcpStates.count ? tcpStates[st] : "\(st)")
        case Int(SOCKINFO_IN):
            let i = s.soi_proto.pri_in
            return .init(fd: fd, proto: s.soi_protocol == IPPROTO_UDP ? "UDP" : "IP", local: addr(i, local: true), remote: addr(i, local: false), state: "")
        case Int(SOCKINFO_UN):
            var u = s.soi_proto.pri_un.unsi_addr.ua_sun
            let path = withUnsafeBytes(of: &u.sun_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return .init(fd: fd, proto: "Unix", local: path.isEmpty ? "(unnamed)" : path, remote: "", state: "")
        default: return nil
        }
    }

    /// Per-thread info. Thread handles come from PROC_PIDLISTTHREADS (capped at 4096, 8 bytes each). `pth_cpu_usage` is
    /// the kernel's decayed usage scaled to 1000 (TH_USAGE_SCALE), so /10 gives % of one core; times are in ns.
    /// Threads that exit between the two calls are skipped.
    static func threads(_ pid: Int32) -> Measured<[ProcessDetails.ThreadInfo]> {
        var ids = [UInt64](repeating: 0, count: 4096)
        let r = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &ids, Int32(ids.count * 8))
        guard r > 0 else { return .unavailable("not permitted") }
        let states = [1: "running", 2: "stopped", 3: "waiting", 4: "uninterruptible", 5: "halted"]
        var out: [ProcessDetails.ThreadInfo] = []
        for id in ids.prefix(Int(r) / 8) {
            var ti = proc_threadinfo()
            guard proc_pidinfo(pid, PROC_PIDTHREADINFO, id, &ti, Int32(MemoryLayout<proc_threadinfo>.size)) > 0 else { continue }
            let name = withUnsafeBytes(of: ti.pth_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            out.append(.init(id: id, name: name, cpu: Double(ti.pth_cpu_usage) / 10, state: states[Int(ti.pth_run_state)] ?? "?",
                             priority: ti.pth_curpri, userTime: Double(ti.pth_user_time) / 1e9, systemTime: Double(ti.pth_system_time) / 1e9))
        }
        return .value(out)
    }

    /// Static code-signature check of the executable (or its .app bundle when it is inside one). Also used by Launchd to
    /// check job programs. nil if the path can't be opened as code. `valid` covers structure and certificate chain only.
    public static func signature(_ path: String) -> ProcessDetails.Signature? {
        let target = AppUsage.bundle(of: path) ?? path
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: target) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        // Structure and certificate chain only: validating every resource of a large app takes minutes.
        let quick = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        let valid = SecStaticCodeCheckValidity(code, quick, nil) == errSecSuccess
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let d = info as? [String: Any] ?? [:]
        let certs = (d[kSecCodeInfoCertificates as String] as? [SecCertificate]) ?? []
        let names = certs.compactMap { SecCertificateCopySubjectSummary($0) as String? }
        let flags = (d[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        // "anchor apple" matches only Apple's own signing chain (not Developer ID apps), so isApple means a system binary.
        var req: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, [], &req)
        let isApple = req.map { SecStaticCodeCheckValidity(code, quick, $0) == errSecSuccess } ?? false
        return .init(identifier: d[kSecCodeInfoIdentifier as String] as? String, teamID: d[kSecCodeInfoTeamIdentifier as String] as? String,
                     // 0x10000 is kSecCodeSignatureRuntime (hardened runtime) in the code-signing flags.
                     authority: names, isApple: isApple, valid: valid, hardenedRuntime: flags & 0x10000 != 0)
    }

    /// The parent chain from `pid` up to launchd (PID 1) or kernel_task, starting with the process itself. Capped at 64
    /// hops so a race (a parent exiting and its PID being reused) can never loop forever. Names prefer proc_name (longer
    /// than p_comm's 15 characters).
    static func ancestry(_ pid: Int32) -> [(pid: Int32, name: String)] {
        var out: [(Int32, String)] = []
        var cur = pid
        for _ in 0..<64 {
            // short BSD info is readable for every process, unlike the full record
            var bsd = proc_bsdshortinfo()
            guard proc_pidinfo(cur, PROC_PIDT_SHORTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0 else { break }
            var name = [CChar](repeating: 0, count: 256)
            let comm = proc_name(cur, &name, 256) > 0 ? String(cString: name)
                : withUnsafeBytes(of: bsd.pbsi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            out.append((cur, comm))
            if cur <= 1 { break }
            cur = Int32(bsd.pbsi_ppid)
        }
        return out
    }

    /// Runs `/usr/bin/sample` for `seconds` and returns its call-tree report (own processes only without root).
    /// Blocks for at least `seconds`; callers (InspectorView, Evidence) run it off the main actor. `-mayDie` keeps sample
    /// from failing if the target exits mid-run; the report is written to a temp file that is deleted after reading.
    public static func sampleStacks(pid: Int32, seconds: Int = 3) -> String {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("flightdeck-sample-\(pid).txt")
        _ = Shell.run("/usr/bin/sample", ["\(pid)", "\(seconds)", "-mayDie", "-file", out.path])
        defer { try? FileManager.default.removeItem(at: out) }
        return (try? String(contentsOf: out, encoding: .utf8)) ?? "sample could not attach to PID \(pid). Processes owned by other users or protected by System Integrity Protection can't be sampled without root."
    }

    /// Sets the nice value (raising priority needs root).
    /// Lowering priority (a higher nice value) is allowed for the user's own processes; throws the POSIX errno otherwise.
    public static func setNice(pid: Int32, _ value: Int32) throws {
        if setpriority(PRIO_PROCESS, id_t(pid), value) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
