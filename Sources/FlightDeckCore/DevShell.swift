import Foundation
import Darwin

// Shared plumbing for the Developer destination: a subprocess runner that keeps the exit status and stderr (the
// generic `Shell.run` discards both, but "the Docker daemon isn't running" only ever arrives on stderr), a locator for
// developer command-line tools, and small own-process helpers (owner uid, executable path, command line).

/// The result of running one tool. `timedOut` is set when the runner had to terminate it.
public struct ToolRun: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var ok: Bool { status == 0 && !timedOut }
    /// The first non-empty stderr line (or stdout if stderr is empty), for showing why a tool failed.
    public var reason: String {
        if timedOut { return "timed out" }
        let line = (stderr + "\n" + stdout).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line ?? "exited with status \(status)"
    }
    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.status = status; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
    }
}

public enum DevShell {
    /// Directories searched for developer tools, in priority order. A GUI app inherits launchd's minimal PATH
    /// (/usr/bin:/bin:/usr/sbin:/sbin), not the user's shell PATH, so Homebrew, rustup, Docker Desktop and friends
    /// have to be looked for where their installers put them. /usr/bin comes last: several of its entries are stubs
    /// (see `isSafeToRun`).
    public static var searchDirs: [String] {
        let h = NSHomeDirectory()
        return ["\(h)/.cargo/bin", "\(h)/.bun/bin", "\(h)/.deno/bin", "\(h)/.volta/bin", "\(h)/.local/bin",
                "\(h)/.orbstack/bin", "\(h)/.rd/bin", "\(h)/.docker/bin",
                "/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin",
                "/Applications/Docker.app/Contents/Resources/bin", "/Applications/OrbStack.app/Contents/MacOS/xbin",
                "\(h)/.pyenv/shims", "\(h)/.rbenv/shims", "\(h)/.nodenv/shims", "\(h)/.asdf/shims",
                "/usr/bin"]
    }

    /// The first executable named `name` in `searchDirs` (or nil). Only checks the file system; runs nothing.
    public static func find(_ name: String) -> String? {
        for d in searchDirs {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// PATH handed to child tools, so a CLI can find its own helpers (docker's credential helpers and plugins, brew's
    /// git) the way it would from Terminal.
    public static var childPATH: String { (searchDirs + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":") }

    /// Runs `path args` with a timeout, capturing stdout, stderr and the exit status. nil only if the executable
    /// couldn't be launched at all. Blocking; call off the main thread. stdin is /dev/null so nothing can wait for input.
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10, env extra: [String: String] = [:]) -> ToolRun? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = childPATH
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timedOut = TimeoutFlag()
        let timer = DispatchWorkItem { if p.isRunning { timedOut.set(); p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // stderr is drained on another thread while stdout is read here: reading the two pipes one after the other
        // could deadlock once the child fills the unread pipe's buffer and blocks.
        let errData = DataBox()
        let g = DispatchGroup(); g.enter()
        DispatchQueue.global().async { errData.data = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait(); p.waitUntilExit(); timer.cancel()
        return ToolRun(status: p.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                       stderr: String(decoding: errData.data, as: UTF8.self), timedOut: timedOut.value)
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    // MARK: Own-process helpers

    /// The effective uid owning `pid`, from the kernel's kinfo_proc record (readable for every user's processes).
    public static func owner(of pid: Int32) -> uid_t? {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    /// True when `pid` belongs to the user running FlightDeck: the only processes the Developer view inspects or acts on.
    public static func isOwn(_ pid: Int32) -> Bool { owner(of: pid) == getuid() }

    /// Executable path via proc_pidpath, or "" when the kernel won't say.
    public static func executable(of pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    /// The process's argv (own processes only; nil when the kernel refuses).
    public static func arguments(of pid: Int32) -> [String]? { ProcessInspector.argsAndEnv(pid).0.value }

    /// Current working directory: for a dev server, the project it was started in.
    public static func workingDirectory(of pid: Int32) -> Measured<String> { ProcessInspector.cwd(pid) }
}
