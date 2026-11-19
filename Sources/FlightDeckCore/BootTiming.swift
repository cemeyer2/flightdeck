import Foundation

// Boot and login timing for Restarts & Crashes, measured without root from facts the kernel keeps anyway:
//   kernel start      kern.boottime (also wtmp's boot record)
//   login window      loginwindow's process start time (it launches once WindowServer is up)
//   login             wtmp's console login record (written when loginwindow accepts the password, or auto-logs in
//                     after a FileVault unlock)
//   desktop           the latest start of the user's Dock, Finder and SystemUIServer: the desktop has begun drawing
//   login items       the user's (and third-party daemons') non-Apple processes that started within 3 minutes of login
// These are launch times, so each phase is accurate to the second but measures when things *started*, not when they
// were ready. Time at the login window includes however long the password took to type. Process start times exist
// only for processes still running, so the full breakdown is measured for the current boot and saved; earlier boots
// keep what was saved for them, plus the boot-to-login time from wtmp.

/// A login or background item seen during login.
public struct BootItem: Sendable, Hashable, Codable, Identifiable {
    public var id: String { name + "|" + (path ?? "") }
    public var name: String
    public var path: String?
    /// "Launch agent", "Launch daemon", "App" (opened at login) or "Background process".
    public var kind: String
    /// Seconds after login it started.
    public var startedAfterLogin: TimeInterval
    /// CPU seconds used: in the first minutes after login (black box) or since it started (see BootTiming.busiestSource).
    public var cpuSeconds: Double?
    public init(name: String, path: String?, kind: String, startedAfterLogin: TimeInterval, cpuSeconds: Double?) {
        self.name = name; self.path = path; self.kind = kind; self.startedAfterLogin = startedAfterLogin; self.cpuSeconds = cpuSeconds
    }
}

public struct BootTiming: Sendable, Hashable, Codable {
    public enum BusiestSource: String, Sendable, Codable {
        case blackBox = "FlightDeck's black box, first 5 minutes after login"
        case sinceStart = "CPU time since each process started (FlightDeck wasn't recording during login)"
    }
    public var boot: Date
    public var loginWindow: Date?
    public var login: Date?
    public var desktop: Date?
    public var itemsDone: Date?
    public var items: [BootItem] = []
    public var busiest: [BootItem] = []
    public var busiestSource: BusiestSource?
    public init(boot: Date) { self.boot = boot }

    public var toLoginWindow: TimeInterval? { loginWindow.map { $0.timeIntervalSince(boot) } }
    /// Time at the login window, including typing the password (nil for automatic logins measured as < 1 s).
    public var atLoginWindow: TimeInterval? { loginWindow.flatMap { w in login.map { $0.timeIntervalSince(w) } } }
    public var loginToDesktop: TimeInterval? { login.flatMap { l in desktop.map { $0.timeIntervalSince(l) } } }
    public var itemsPhase: TimeInterval? { (desktop ?? login).flatMap { d in itemsDone.map { max($0.timeIntervalSince(d), 0) } } }
    public var bootToLogin: TimeInterval? { login.map { $0.timeIntervalSince(boot) } }
    public var bootToDesktop: TimeInterval? { desktop.map { $0.timeIntervalSince(boot) } }
}

/// The few process facts timing needs, so tests don't build whole ProcessSamples.
public struct BootProcess: Sendable, Hashable {
    public var name: String, path: String, start: Date, uid: UInt32, ppid: Int32, cpuTime: Double
    public init(name: String, path: String, start: Date, uid: UInt32, ppid: Int32, cpuTime: Double) {
        self.name = name; self.path = path; self.start = start; self.uid = uid; self.ppid = ppid; self.cpuTime = cpuTime
    }
    public init(_ p: ProcessSample) { self.init(name: p.name, path: p.path, start: p.startDate, uid: p.uid, ppid: p.ppid, cpuTime: p.cpuTime) }
}

public enum BootTimer {
    /// How long after login a starting process still counts as part of the login phase.
    public static let itemsWindow: TimeInterval = 180
    /// The black-box window used for "busiest after login".
    public static let busyWindow: TimeInterval = 300

    /// Apple's own code lives here; everything else is a third-party item.
    static func isApple(_ path: String) -> Bool {
        path.isEmpty || ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/", "/Library/Developer/CommandLineTools/"].contains { path.hasPrefix($0) }
    }

    /// The app bundle a path is inside ("/Applications/Foo.app"), so helpers group with their app.
    static func bundle(_ path: String) -> String? { path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } }

    /// Computes the phases and the login items. `agents`/`daemons` are program paths from the LaunchAgents and
    /// LaunchDaemons plists, used only to name the kind. Root processes count only when a LaunchDaemon plist names them.
    public static func compute(boot: Date, login: Date?, processes: [BootProcess], uid: UInt32,
                               agents: Set<String> = [], daemons: Set<String> = []) -> BootTiming {
        var t = BootTiming(boot: boot)
        t.login = login
        let limit = login ?? boot.addingTimeInterval(600)
        t.loginWindow = processes.filter { $0.name == "loginwindow" && $0.start >= boot && $0.start <= limit }.map(\.start).min()
        guard let login else { return t }
        let shell = processes.filter { ["Dock", "Finder", "SystemUIServer"].contains($0.name) && $0.uid == uid
            && $0.start >= login && $0.start <= login.addingTimeInterval(600) }
        t.desktop = shell.map(\.start).max()
        // Login items: third-party processes started in the window, grouped by app bundle.
        let candidates = processes.filter { p in
            p.start >= login.addingTimeInterval(-5) && p.start <= login.addingTimeInterval(itemsWindow) && !isApple(p.path)
                && (p.uid == uid || p.uid == 0 && daemons.contains(p.path))
        }
        var groups: [String: (item: BootItem, start: Date)] = [:]
        for p in candidates {
            let key = bundle(p.path) ?? p.path
            let kind = agents.contains(p.path) ? "Launch agent" : daemons.contains(p.path) ? "Launch daemon"
                : (bundle(p.path) != nil && p.ppid == 1 ? "App" : "Background process")
            let name = bundle(p.path).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? p.name
            if var g = groups[key] {
                g.item.cpuSeconds = (g.item.cpuSeconds ?? 0) + p.cpuTime
                if p.start < g.start { g.start = p.start; g.item.startedAfterLogin = max(p.start.timeIntervalSince(login), 0) }
                if kind != "Background process" && g.item.kind == "Background process" { g.item.kind = kind }
                groups[key] = g
            } else {
                groups[key] = (BootItem(name: name, path: key, kind: kind, startedAfterLogin: max(p.start.timeIntervalSince(login), 0), cpuSeconds: p.cpuTime), p.start)
            }
        }
        t.items = groups.values.map(\.item).sorted { $0.startedAfterLogin < $1.startedAfterLogin }
        t.itemsDone = candidates.map(\.start).max()   // the last process (helpers too) to start in the window
        return t
    }

    /// The busiest processes in the first `busyWindow` seconds after login, from black-box frames. Needs frames that
    /// start within a minute of login (FlightDeck itself started at login); otherwise nil and the caller falls back
    /// to CPU time since start. CPU used = the process's cumulative CPU time at its last frame in the window minus the
    /// value it had at login (0 if it started after login, else its first frame's value, a slight undercount).
    /// The black box keeps only the 25 busiest processes per frame, so quieter ones aren't listed.
    public static func busiest(frames: [Snapshot], login: Date, limit: Int = 8) -> [BootItem]? {
        let window = frames.filter { $0.time >= login && $0.time <= login.addingTimeInterval(busyWindow) }
        guard let first = window.first, first.time.timeIntervalSince(login) <= 60, window.count >= 2 else { return nil }
        var start: [ProcessIdentity: Double] = [:], last: [ProcessIdentity: (ProcessSample, Double)] = [:]
        for f in window {
            for p in f.processes {
                if start[p.identity] == nil { start[p.identity] = p.startDate >= login ? 0 : p.cpuTime }
                last[p.identity] = (p, p.cpuTime)
            }
        }
        var byName: [String: (BootItem, Double)] = [:]
        for (id, v) in last {
            let used = max(v.1 - (start[id] ?? 0), 0)
            let key = bundle(v.0.path) ?? v.0.name
            let name = bundle(v.0.path).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? v.0.name
            let after = max(v.0.startDate.timeIntervalSince(login), 0)
            let prev = byName[key]
            byName[key] = (BootItem(name: name, path: v.0.path, kind: isApple(v.0.path) ? "macOS" : "Third-party", startedAfterLogin: min(after, prev?.0.startedAfterLogin ?? after),
                                    cpuSeconds: (prev?.1 ?? 0) + used), (prev?.1 ?? 0) + used)
        }
        return byName.values.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Program paths from the LaunchAgents and LaunchDaemons plists (Program or ProgramArguments[0]). Reads plists only,
    /// no signature checks, so it is fast.
    public static func launchPrograms() -> (agents: Set<String>, daemons: Set<String>) {
        func read(_ dirs: [String]) -> Set<String> {
            Set(dirs.flatMap { d -> [String] in
                ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).filter { $0.hasSuffix(".plist") }.compactMap { f in
                    guard let p = NSDictionary(contentsOfFile: d + "/" + f) as? [String: Any] else { return nil }
                    return (p["Program"] as? String) ?? (p["ProgramArguments"] as? [String])?.first
                }
            })
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (read([home + "/Library/LaunchAgents", "/Library/LaunchAgents"]), read(["/Library/LaunchDaemons"]))
    }
}
