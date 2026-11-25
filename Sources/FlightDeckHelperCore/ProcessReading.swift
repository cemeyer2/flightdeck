import Foundation
import Darwin
import FlightDeckHelperProtocol

/// The helper's per-process reads, behind a protocol so the PID re-check rules are testable with a fake.
public protocol ProcessReading: AnyObject {
    func identity(of pid: Int32) -> HelperProcessID?
    func name(of pid: Int32) -> String?
    func rusage(of pid: Int32) -> HelperRusage?
    func contents(of pid: Int32, parts: Set<DetailPart>) -> HelperProcessContents
}

/// libproc and sysctl, as root. Mirrors what FlightDeckCore's ProcessSampler and ProcessDetails read for the user's
/// own processes; not unit-tested (it needs root to differ from what the app reads itself).
public final class LibprocProcessReader: ProcessReading {
    private let timebase: (UInt32, UInt32) = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return (tb.numer, tb.denom)
    }()

    public init() {}

    private func ns(_ ticks: UInt64) -> UInt64 { ticks &* UInt64(timebase.0) / UInt64(max(timebase.1, 1)) }

    public func identity(of pid: Int32) -> HelperProcessID? {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size)
        else { return nil }
        return HelperProcessID(pid: pid, startTime: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec)
    }

    public func name(of pid: Int32) -> String? {
        if pid == 0 { return "kernel_task" }
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    public func rusage(of pid: Int32) -> HelperRusage? {
        var ru = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        } == 0
        guard ok else { return nil }
        var ti = proc_taskinfo()
        let tiOK = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size)
        return HelperRusage(cpuNs: ns(ru.ri_user_time &+ ru.ri_system_time), diskRead: ru.ri_diskio_bytesread,
                            diskWritten: ru.ri_diskio_byteswritten, energyNJ: ru.ri_energy_nj,
                            idleWakeups: ru.ri_pkg_idle_wkups, physFootprint: ru.ri_phys_footprint,
                            threads: tiOK ? Int(ti.pti_threadnum) : nil)
    }

    public func contents(of pid: Int32, parts: Set<DetailPart>) -> HelperProcessContents {
        var c = HelperProcessContents()
        if parts.contains(.args) || parts.contains(.env), let ae = procArgs(pid) {
            if parts.contains(.args) { c.args = ae.args }
            if parts.contains(.env) { c.env = ae.env }
        }
        if parts.contains(.cwd) {
            var vi = proc_vnodepathinfo()
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vi, Int32(MemoryLayout<proc_vnodepathinfo>.size)) == Int32(MemoryLayout<proc_vnodepathinfo>.size) {
                c.cwd = withUnsafeBytes(of: vi.pvi_cdir.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            }
        }
        if parts.contains(.files) || parts.contains(.sockets) {
            let (files, sockets) = openFiles(pid)
            if parts.contains(.files) { c.files = files }
            if parts.contains(.sockets) { c.sockets = sockets }
        }
        return c
    }

    private func procArgs(_ pid: Int32) -> (args: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return HelperParsers.procArgs(Array(buf.prefix(size)))
    }

    /// Open vnode paths and socket endpoints, as display strings ("TCP 127.0.0.1:8080 → 10.0.0.2:443").
    private func openFiles(_ pid: Int32) -> ([String], [String]) {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return ([], []) }
        let n = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: n + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard got > 0 else { return ([], []) }
        var files: [String] = [], sockets: [String] = []
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) {
            if fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var vi = vnode_fdinfowithpath()
                let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
                if r == Int32(MemoryLayout<vnode_fdinfowithpath>.size) {
                    let p = withUnsafeBytes(of: vi.pvip.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
                    if !p.isEmpty { files.append(p) }
                }
            } else if fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var si = socket_fdinfo()
                let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size))
                if r == Int32(MemoryLayout<socket_fdinfo>.size), let s = socketString(si.psi) { sockets.append(s) }
            }
        }
        return (files, sockets)
    }

    private func socketString(_ s: socket_info) -> String? {
        guard s.soi_family == AF_INET || s.soi_family == AF_INET6 else { return nil }
        let proto = s.soi_protocol == IPPROTO_TCP ? "TCP" : (s.soi_protocol == IPPROTO_UDP ? "UDP" : "IP")
        let ins = s.soi_kind == SOCKINFO_TCP ? s.soi_proto.pri_tcp.tcpsi_ini : s.soi_proto.pri_in
        func addr(_ v4: in4in6_addr, _ v6: in6_addr, _ port: Int32) -> String {
            let p = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: port)))
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if ins.insi_vflag & UInt8(INI_IPV4) != 0 {
                var a = v4.i46a_addr4
                inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
                return "\(String(cString: buf)):\(p)"
            }
            var a = v6
            inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
            return "[\(String(cString: buf))]:\(p)"
        }
        let local = addr(ins.insi_laddr.ina_46, ins.insi_laddr.ina_6, ins.insi_lport)
        if ins.insi_fport == 0 { return "\(proto) \(local)" }
        return "\(proto) \(local) → \(addr(ins.insi_faddr.ina_46, ins.insi_faddr.ina_6, ins.insi_fport))"
    }
}
