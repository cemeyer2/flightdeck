import Foundation
import Darwin

/// PID + start time: guards against acting on a recycled PID.
public struct ProcessIdentity: Codable, Sendable, Hashable {
    public var pid: Int32
    public var startTime: UInt64   // microseconds since epoch
    public init(pid: Int32, startTime: UInt64) { self.pid = pid; self.startTime = startTime }
}

public struct ProcessSample: Codable, Sendable, Identifiable, Hashable {
    public var id: ProcessIdentity { identity }
    public var identity: ProcessIdentity
    public var pid: Int32 { identity.pid }
    public var ppid: Int32
    public var name: String
    public var path: String
    public var user: String
    public var uid: UInt32
    public var cpu: Double            // % of one core
    public var cpuTime: Double        // seconds
    public var memory: UInt64         // phys footprint
    public var threads: Int
    public var diskReadBps: Double
    public var diskWriteBps: Double
    public var diskRead: UInt64
    public var diskWritten: UInt64
    public var energyWatts: Double?   // from billed energy, nil if not reported
    public var wakeups: Double        // idle wakeups/s
    public var restricted: Bool       // couldn't read full info (other user's process)
    /// nil = network sampling unavailable or warming up. Present for every process once nettop works.
    public var network: ProcessNetwork? = nil
    /// GUI apps only: true while the window server considers it hung. nil = not a GUI app / unknown.
    public var notResponding: Bool? = nil
    /// Share of GPU time (%) over the last sample; nil = this process has no GPU client.
    public var gpu: Double? = nil
    /// true = an Intel binary running under Rosetta 2; nil = unknown.
    public var translated: Bool? = nil
    /// Power assertions this process holds that keep the Mac or display awake (nil = none).
    public var powerAssertions: [PowerAssertion]? = nil
    public var startDate: Date { Date(timeIntervalSince1970: Double(identity.startTime) / 1e6) }
}

public final class ProcessSampler {
    struct Prev { var cpuNs: UInt64; var r: UInt64; var w: UInt64; var energy: UInt64; var wake: UInt64 }
    private var prev: [ProcessIdentity: Prev] = [:]
    private var lastTime: Date?
    private var userCache: [UInt32: String] = [:]
    private var pathCache: [ProcessIdentity: (String, String)] = [:]
    private var translatedCache: [ProcessIdentity: Bool] = [:]

    /// Rosetta translation flag from the kernel's process record (P_TRANSLATED).
    static func isTranslated(_ pid: Int32) -> Bool? {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_proc.p_flag & 0x20000 != 0
    }
    private let timebase: (UInt32, UInt32) = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return (tb.numer, tb.denom)
    }()
    public var includeSelf = true
    public init() {}

    private func ns(_ ticks: UInt64) -> UInt64 { ticks &* UInt64(timebase.0) / UInt64(max(timebase.1, 1)) }

    private func userName(_ uid: UInt32) -> String {
        if let u = userCache[uid] { return u }
        let n = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "\(uid)"
        userCache[uid] = n; return n
    }

    public static func allPIDs() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let c = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(c, 0)))).filter { $0 >= 0 }
    }

    public static func identity(of pid: Int32) -> ProcessIdentity? {
        var bsd = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard r == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return ProcessIdentity(pid: pid, startTime: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec)
    }

    public func sample() -> [ProcessSample] {
        let now = Date()
        let dt = lastTime.map { max(now.timeIntervalSince($0), 0.001) }
        var next: [ProcessIdentity: Prev] = [:]
        var out: [ProcessSample] = []
        let me = getpid()
        for pid in Self.allPIDs() {
            if !includeSelf && pid == me { continue }
            var all = proc_taskallinfo()
            let sz = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all, Int32(MemoryLayout<proc_taskallinfo>.size))
            var bsd: proc_bsdinfo
            var restricted = false
            if sz == Int32(MemoryLayout<proc_taskallinfo>.size) {
                bsd = all.pbsd
            } else {
                bsd = proc_bsdinfo()
                let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
                if r != Int32(MemoryLayout<proc_bsdinfo>.size) {
                    // shortbsdinfo works for other users' processes
                    var sb = proc_bsdshortinfo()
                    let r2 = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &sb, Int32(MemoryLayout<proc_bsdshortinfo>.size))
                    if r2 != Int32(MemoryLayout<proc_bsdshortinfo>.size) && pid != 0 { continue }
                    bsd.pbi_ppid = sb.pbsi_ppid; bsd.pbi_uid = sb.pbsi_uid
                    bsd.pbi_comm = sb.pbsi_comm
                }
                restricted = true
            }
            let ident = ProcessIdentity(pid: pid, startTime: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec)

            var ru = rusage_info_v6()
            let ruOK = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            } == 0

            let cpuNs: UInt64 = ruOK ? ns(ru.ri_user_time &+ ru.ri_system_time)
                : (restricted ? 0 : ns(all.ptinfo.pti_total_user &+ all.ptinfo.pti_total_system))
            let cur = Prev(cpuNs: cpuNs, r: ruOK ? ru.ri_diskio_bytesread : 0, w: ruOK ? ru.ri_diskio_byteswritten : 0,
                           energy: ruOK ? ru.ri_energy_nj : 0, wake: ruOK ? ru.ri_pkg_idle_wkups : 0)
            next[ident] = cur

            var cpu = 0.0, rb = 0.0, wb = 0.0, wk = 0.0
            var energy: Double? = nil
            if let dt, let p = prev[ident] {
                func d(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) : 0 }   // never a wrap-around spike
                cpu = d(cur.cpuNs, p.cpuNs) / 1e9 / dt * 100
                rb = d(cur.r, p.r) / dt
                wb = d(cur.w, p.w) / dt
                wk = d(cur.wake, p.wake) / dt
                if ruOK { energy = d(cur.energy, p.energy) / 1e9 / dt }   // nJ -> W
            }
            let comm = withUnsafeBytes(of: bsd.pbi_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            let (name, path) = names(pid: pid, ident: ident, comm: comm)
            if translatedCache[ident] == nil, let t = Self.isTranslated(pid) { translatedCache[ident] = t }
            out.append(ProcessSample(
                identity: ident, ppid: Int32(bsd.pbi_ppid), name: name, path: path,
                user: userName(bsd.pbi_uid), uid: bsd.pbi_uid,
                cpu: max(cpu, 0), cpuTime: Double(cpuNs) / 1e9,
                memory: ruOK ? ru.ri_phys_footprint : (restricted ? 0 : all.ptinfo.pti_resident_size),
                threads: restricted ? 0 : Int(all.ptinfo.pti_threadnum),
                diskReadBps: rb, diskWriteBps: wb, diskRead: cur.r, diskWritten: cur.w,
                energyWatts: energy, wakeups: wk, restricted: restricted && !ruOK))
            out[out.count - 1].translated = translatedCache[ident]
        }
        prev = next; lastTime = now
        pathCache = pathCache.filter { next[$0.key] != nil }
        translatedCache = translatedCache.filter { next[$0.key] != nil }
        return out
    }

    private func names(pid: Int32, ident: ProcessIdentity, comm: String) -> (String, String) {
        if let c = pathCache[ident] { return c }
        var pbuf = [CChar](repeating: 0, count: 4096)
        let pl = proc_pidpath(pid, &pbuf, UInt32(pbuf.count))
        let path = pl > 0 ? String(cString: pbuf) : ""
        var nbuf = [CChar](repeating: 0, count: 256)
        var name = proc_name(pid, &nbuf, UInt32(nbuf.count)) > 0 ? String(cString: nbuf) : ""
        if name.isEmpty { name = comm }
        if !path.isEmpty, let app = path.range(of: ".app/Contents/MacOS/") {
            let bundle = path[..<app.lowerBound]
            let appName = (bundle as NSString).lastPathComponent
            if path.hasSuffix("/" + appName) || name.count >= 15 { name = appName }
        } else if name.count >= 15, !path.isEmpty { name = (path as NSString).lastPathComponent }
        if pid == 0 { name = "kernel_task" }
        // Only cache successes: a transient failure (e.g. right at exec) must not hide the path forever.
        if !path.isEmpty { pathCache[ident] = (name, path) }
        return (name, path)
    }

    // MARK: Actions (identity-checked)
    public enum ActionError: Error, LocalizedError {
        case identityMismatch, failed(Int32)
        public var errorDescription: String? {
            switch self {
            case .identityMismatch: return "The process has exited and its PID was reused. No action was taken."
            case .failed(let e): return String(cString: strerror(e))
            }
        }
    }
    public static func send(_ sig: Int32, to ident: ProcessIdentity) throws {
        guard identity(of: ident.pid) == ident else { throw ActionError.identityMismatch }
        if kill(ident.pid, sig) != 0 { throw ActionError.failed(errno) }
    }
}
