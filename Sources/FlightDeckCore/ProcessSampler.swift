import Foundation
import Darwin

// The per-process table: enumerates every PID with libproc (proc_listallpids / proc_pidinfo / proc_pid_rusage) and
// turns cumulative kernel counters into per-second rates by diffing against the previous sample. Sampler
// (Snapshot.swift) then decorates each ProcessSample with network, GPU, hang and power-assertion data from other
// sources. Also hosts the identity-checked signal action used by Quit / Force Quit.
/// PID + start time: guards against acting on a recycled PID.
/// PIDs are reused quickly on macOS, so every per-process cache, history and action is keyed by this pair instead
/// of the bare PID. The start time comes from proc_bsdinfo (pbi_start_tvsec/usec) and is fixed for a process's life.
public struct ProcessIdentity: Codable, Sendable, Hashable {
    public var pid: Int32
    public var startTime: UInt64   // microseconds since epoch
    public init(pid: Int32, startTime: UInt64) { self.pid = pid; self.startTime = startTime }
}

/// One process at one moment. Rates (cpu, disk, wakeups, energy) are averages over the interval since the previous
/// sample; totals (cpuTime, diskRead, diskWritten) are cumulative since the process started. Codable because
/// snapshots are recorded into Flight Recorder traces.
public struct ProcessSample: Codable, Sendable, Identifiable, Hashable {
    public var id: ProcessIdentity { identity }
    public var identity: ProcessIdentity
    public var pid: Int32 { identity.pid }
    public var ppid: Int32
    /// Display name: the app bundle name for app executables, otherwise proc_name / the executable file name.
    public var name: String
    /// Full executable path from proc_pidpath; "" when the kernel won't reveal it.
    public var path: String
    public var user: String
    public var uid: UInt32
    public var cpu: Double            // % of one core
    public var cpuTime: Double        // seconds
    public var memory: UInt64         // phys footprint
    public var threads: Int
    /// Bytes/s read from and written to storage, from rusage's ri_diskio_* counters (storage I/O attributed to the
    /// process; reads satisfied from the file cache don't count). 0 when rusage is unavailable for the process.
    public var diskReadBps: Double
    public var diskWriteBps: Double
    /// Cumulative bytes read / written since the process started.
    public var diskRead: UInt64
    public var diskWritten: UInt64
    public var energyWatts: Double?   // from billed energy, nil if not reported
    /// Cumulative billed energy since the process started, in joules (nil if not reported). Recorded so long-range
    /// totals can be computed exactly from any two recorded frames, however sparse (see `Cumulative`).
    public var energyTotal: Double? = nil
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

/// Produces the process list each tick. Stateful (it remembers the previous counters to compute rates) and not
/// thread-safe: owned by Sampler and only called on the app's sampling queue.
public final class ProcessSampler {
    /// Cumulative counters from the previous sample, used to compute deltas. CPU is already converted to ns;
    /// disk in bytes, energy in nanojoules, wakeups as a count.
    struct Prev { var cpuNs: UInt64; var r: UInt64; var w: UInt64; var energy: UInt64; var wake: UInt64 }
    private var prev: [ProcessIdentity: Prev] = [:]
    private var lastTime: Date?
    private var userCache: [UInt32: String] = [:]
    /// (name, path) per process. Paths never change for a given identity, and proc_pidpath is comparatively costly,
    /// so it is resolved once. Pruned every sample to processes still alive.
    private var pathCache: [ProcessIdentity: (String, String)] = [:]
    private var translatedCache: [ProcessIdentity: Bool] = [:]

    /// Rosetta translation flag from the kernel's process record (P_TRANSLATED).
    /// Read via sysctl KERN_PROC_PID because libproc doesn't expose p_flag. 0x20000 is P_TRANSLATED from
    /// <sys/proc.h>, which isn't imported into Swift. nil if the process vanished or the sysctl failed.
    static func isTranslated(_ pid: Int32) -> Bool? {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_proc.p_flag & 0x20000 != 0
    }
    /// Mach timebase (numer/denom) for converting mach_absolute_time ticks to nanoseconds. On Intel it is 1/1;
    /// on Apple silicon ticks are 24 MHz (125/3), and rusage/task CPU times are reported in ticks, not ns.
    private let timebase: (UInt32, UInt32) = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return (tb.numer, tb.denom)
    }()
    /// Whether FlightDeck lists itself. Engine sets this from the user's preference before each sample.
    public var includeSelf = true
    public init() {}

    /// Mach ticks to nanoseconds. Wrapping multiply so a pathological counter can't trap; real values are far below
    /// the overflow point.
    private func ns(_ ticks: UInt64) -> UInt64 { ticks &* UInt64(timebase.0) / UInt64(max(timebase.1, 1)) }

    /// uid to login name via getpwuid, cached (directory lookups can be slow). Falls back to the numeric uid.
    private func userName(_ uid: UInt32) -> String {
        if let u = userCache[uid] { return u }
        let n = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "\(uid)"
        userCache[uid] = n; return n
    }

    /// Every PID currently alive (including PID 0, kernel_task). The first call asks how many PIDs exist; the buffer
    /// gets 64 spare slots for processes spawned between the two calls. The second call returns the number of PIDs
    /// actually written, which bounds the result.
    public static func allPIDs() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let c = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(c, 0)))).filter { $0 >= 0 }
    }

    /// The current identity of `pid`, or nil if it doesn't exist or its BSD info can't be read (e.g. another user's
    /// process without root). Used to re-verify a target right before acting on it.
    public static func identity(of pid: Int32) -> ProcessIdentity? {
        var bsd = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
        // proc_pidinfo returns the number of bytes filled; anything short of the full struct is a failure.
        if r == Int32(MemoryLayout<proc_bsdinfo>.size) {
            return ProcessIdentity(pid: pid, startTime: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec)
        }
        // Other users' processes refuse proc_bsdinfo; the kernel's kinfo_proc record still has their start time.
        return startTime(pid).map { ProcessIdentity(pid: pid, startTime: $0) }
    }

    /// Start time (µs since 1970) from `sysctl kern.proc.pid`, which works for every user's processes.
    static func startTime(_ pid: Int32) -> UInt64? {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return UInt64(tv.tv_sec) * 1_000_000 + UInt64(tv.tv_usec)
    }

    /// Samples every process. The first call (and a process's first appearance) has no previous counters, so its rates
    /// are 0 and energy is nil; totals are still valid. Processes that exit between enumeration and query are skipped.
    public func sample() -> [ProcessSample] {
        let now = Date()
        // Measured wall-clock interval rather than the nominal timer interval, so rates stay correct when a tick is
        // late or the background cadence is slower. Clamped to 1 ms to avoid dividing by zero.
        let dt = lastTime.map { max(now.timeIntervalSince($0), 0.001) }
        var next: [ProcessIdentity: Prev] = [:]
        var out: [ProcessSample] = []
        let me = getpid()
        for pid in Self.allPIDs() {
            if !includeSelf && pid == me { continue }
            // Try the richest query first. PROC_PIDTASKALLINFO (BSD info + task info: threads, resident size, CPU
            // times) only succeeds for our own user's processes unless running as root. Fall back to BSD info alone,
            // then to the short BSD info, which macOS returns for any process; anything below the full query is
            // marked restricted.
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
                    // It carries no start time, so that comes from kinfo_proc instead (below), keeping identities real.
                    // A process that fails even this has exited; PID 0 is kept regardless so kernel_task always shows.
                    var sb = proc_bsdshortinfo()
                    let r2 = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &sb, Int32(MemoryLayout<proc_bsdshortinfo>.size))
                    if r2 != Int32(MemoryLayout<proc_bsdshortinfo>.size) && pid != 0 { continue }
                    bsd.pbi_ppid = sb.pbsi_ppid; bsd.pbi_uid = sb.pbsi_uid
                    bsd.pbi_comm = sb.pbsi_comm
                }
                restricted = true
            }
            var start = bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec
            if start == 0, let s = Self.startTime(pid) { start = s }
            let ident = ProcessIdentity(pid: pid, startTime: start)

            // rusage v6 is the source for CPU time, physical footprint, disk I/O, billed energy and idle wakeups. It
            // can succeed even where task info was refused, so it is tried for every process. The C API takes a
            // `rusage_info_t *` (pointer to an opaque pointer), hence the rebind of the struct's address.
            var ru = rusage_info_v6()
            let ruOK = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            } == 0

            // CPU time prefers rusage, then task info; both are in mach ticks and converted to ns. A restricted process
            // with no rusage gets 0 here (shown as restricted in the UI rather than as a real idle process).
            let cpuNs: UInt64 = ruOK ? ns(ru.ri_user_time &+ ru.ri_system_time)
                : (restricted ? 0 : ns(all.ptinfo.pti_total_user &+ all.ptinfo.pti_total_system))
            let cur = Prev(cpuNs: cpuNs, r: ruOK ? ru.ri_diskio_bytesread : 0, w: ruOK ? ru.ri_diskio_byteswritten : 0,
                           energy: ruOK ? ru.ri_energy_nj : 0, wake: ruOK ? ru.ri_pkg_idle_wkups : 0)
            next[ident] = cur

            var cpu = 0.0, rb = 0.0, wb = 0.0, wk = 0.0
            var energy: Double? = nil
            // Rates need the same identity in the previous sample; a recycled PID starts fresh. The counters are
            // monotonic for a live process, but if one ever goes backwards (or a source switched between rusage and
            // task info) the delta is clamped to 0 instead of producing a huge unsigned wrap-around value.
            if let dt, let p = prev[ident] {
                func d(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) : 0 }   // never a wrap-around spike
                cpu = d(cur.cpuNs, p.cpuNs) / 1e9 / dt * 100
                rb = d(cur.r, p.r) / dt
                wb = d(cur.w, p.w) / dt
                wk = d(cur.wake, p.wake) / dt
                // Energy is only reported when rusage worked; otherwise nil, never an invented 0 W.
                if ruOK { energy = d(cur.energy, p.energy) / 1e9 / dt }   // nJ -> W
            } else if let last = lastTime, ident.startTime > 0 {
                // A process that started since the last sample has no previous reading, but its counters started at zero
                // when it launched: its average since launch is a real measurement, not a guess (rather than showing 0%).
                let started = Date(timeIntervalSince1970: Double(ident.startTime) / 1e6)
                let age = now.timeIntervalSince(started)
                if started >= last, age > 0.05 {
                    cpu = Double(cur.cpuNs) / 1e9 / age * 100
                    rb = Double(cur.r) / age; wb = Double(cur.w) / age; wk = Double(cur.wake) / age
                    if ruOK { energy = Double(cur.energy) / 1e9 / age }
                }
            }
            // pbi_comm is a fixed-size C char tuple (MAXCOMLEN + 1), so read it as raw bytes up to the first NUL.
            let comm = withUnsafeBytes(of: bsd.pbi_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            let (name, path) = names(pid: pid, ident: ident, comm: comm)
            // The Rosetta flag can't change during a process's life, so it is queried once per identity.
            if translatedCache[ident] == nil, let t = Self.isTranslated(pid) { translatedCache[ident] = t }
            // Memory is the physical footprint (what Activity Monitor's Memory column shows), falling back to resident
            // size from task info. Threads are only available from task info, so restricted processes report 0.
            out.append(ProcessSample(
                identity: ident, ppid: Int32(bsd.pbi_ppid), name: name, path: path,
                user: userName(bsd.pbi_uid), uid: bsd.pbi_uid,
                cpu: max(cpu, 0), cpuTime: Double(cpuNs) / 1e9,
                memory: ruOK ? ru.ri_phys_footprint : (restricted ? 0 : all.ptinfo.pti_resident_size),
                threads: restricted ? 0 : Int(all.ptinfo.pti_threadnum),
                diskReadBps: rb, diskWriteBps: wb, diskRead: cur.r, diskWritten: cur.w,
                energyWatts: energy, wakeups: wk, restricted: restricted && !ruOK))
            out[out.count - 1].translated = translatedCache[ident]
            if ruOK { out[out.count - 1].energyTotal = Double(cur.energy) / 1e9 }   // nJ -> J
        }
        // Replace (not merge) the previous counters, which also forgets exited processes; prune caches the same way.
        prev = next; lastTime = now
        pathCache = pathCache.filter { next[$0.key] != nil }
        translatedCache = translatedCache.filter { next[$0.key] != nil }
        return out
    }

    /// Resolves a process's display name and executable path. The kernel's p_comm is limited to 15 visible characters
    /// (MAXCOMLEN 16 incl. NUL), so a 15+-character name is treated as possibly truncated and replaced by the path's
    /// file name. For executables inside an .app bundle, the bundle name is preferred ("Google Chrome" rather than a
    /// truncated binary name) when the binary is the app's main executable or the short name looks truncated.
    private func names(pid: Int32, ident: ProcessIdentity, comm: String) -> (String, String) {
        if let c = pathCache[ident] { return c }
        // 4096 = PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN).
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
        // PID 0 has no path or proc_name; give it the name Activity Monitor uses.
        if pid == 0 { name = "kernel_task" }
        // Only cache successes: a transient failure (e.g. right at exec) must not hide the path forever.
        if !path.isEmpty { pathCache[ident] = (name, path) }
        return (name, path)
    }

    // MARK: Actions (identity-checked)
    /// Why a process action was refused or failed.
    public enum ActionError: Error, LocalizedError {
        case identityMismatch, failed(Int32)
        public var errorDescription: String? {
            switch self {
            case .identityMismatch: return "The process has exited and its PID was reused. No action was taken."
            case .failed(let e): return String(cString: strerror(e))
            }
        }
    }
    /// Sends `sig` (e.g. SIGTERM, SIGKILL, SIGSTOP) only if `ident.pid` still belongs to the same process, so a stale
    /// row in the UI can never signal an unrelated process that inherited the PID. Throws identityMismatch when the
    /// process is gone, recycled, or its start time can't be read; `.failed(errno)` if kill(2) refuses (e.g. EPERM for
    /// another user's process). There is a tiny window between the check and kill(2) that can't be closed from user space.
    public static func send(_ sig: Int32, to ident: ProcessIdentity) throws {
        guard identity(of: ident.pid) == ident else { throw ActionError.identityMismatch }
        if kill(ident.pid, sig) != 0 { throw ActionError.failed(errno) }
    }
}
