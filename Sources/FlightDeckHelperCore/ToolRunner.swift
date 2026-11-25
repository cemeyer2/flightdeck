import Foundation
import FlightDeckHelperProtocol

public enum ToolResult: Sendable, Equatable { case output(String), tooLarge, failed, timedOut }

public protocol ToolRunning: AnyObject {
    func run(_ tool: HelperTool) -> ToolResult
}

/// Every tool the helper may run, as root. Paths and argument arrays are constants; the only interpolated values
/// are a validated PID and sample length, rendered with String(_:). There is no case that takes a string.
public enum HelperTool: Sendable, Hashable {
    case netstatTCP, netstatUDP, lsofListening, lsofInternet, tmutilSnapshots, profilesDevice, sfltoolDumpbtm
    case sample(pid: Int32, seconds: Int), footprint(pid: Int32)

    public var path: String {
        switch self {
        case .netstatTCP, .netstatUDP: return "/usr/sbin/netstat"
        case .lsofListening, .lsofInternet: return "/usr/sbin/lsof"
        case .tmutilSnapshots: return "/usr/bin/tmutil"
        case .profilesDevice: return "/usr/bin/profiles"
        case .sfltoolDumpbtm: return "/usr/bin/sfltool"
        case .sample: return "/usr/bin/sample"
        case .footprint: return "/usr/bin/footprint"
        }
    }

    public var arguments: [String] {
        switch self {
        case .netstatTCP: return ["-anv", "-p", "tcp"]
        case .netstatUDP: return ["-anv", "-p", "udp"]
        // -F output, so the app parses it with the same ListeningPorts.parseLsof it uses for its own lsof run.
        case .lsofListening: return ["-nP", "-iTCP", "-sTCP:LISTEN", "-iUDP", "-FpcPn"]
        case .lsofInternet: return ["-nP", "-i", "-FpcPnT"]   // same as Connections.list
        // No tmutil subcommand was found that sizes local snapshots (checked on macOS 26 without root); this lists
        // them, and HelperParsers.snapshotSizes picks up sizes only if root's output carries them.
        case .tmutilSnapshots: return ["listlocalsnapshots", "/"]
        case .profilesDevice: return ["list", "-all"]
        case .sfltoolDumpbtm: return ["dumpbtm"]
        case .sample(let pid, let seconds): return [String(pid), String(seconds)]
        case .footprint(let pid): return [String(pid)]
        }
    }
}

/// Runs a tool with a cap on stdout and a deadline. Unlike FlightDeckCore's Shell.run (unbounded, and not linked
/// here), output past the cap kills the child and reports tooLarge instead of truncating silently. stderr is
/// discarded.
public final class BoundedToolRunner: ToolRunning {
    let maxBytes: Int
    let timeout: TimeInterval

    public init(maxBytes: Int = HelperLimits.maxOutputBytes, timeout: TimeInterval = HelperLimits.toolTimeout) {
        self.maxBytes = maxBytes; self.timeout = timeout
    }

    public func run(_ tool: HelperTool) -> ToolResult { run(path: tool.path, arguments: tool.arguments) }

    func run(path: String, arguments: [String]) -> ToolResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        let lock = NSLock()
        var data = Data()
        var overflow = false
        let eof = DispatchSemaphore(value: 0)
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                eof.signal()
                return
            }
            lock.lock()
            if !overflow {
                data.append(chunk)
                if data.count > self.maxBytes { overflow = true; data = Data() }
            }
            let kill = overflow
            lock.unlock()
            if kill, p.isRunning { p.terminate() }
        }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return .failed
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            out.fileHandleForReading.readabilityHandler = nil
            return .timedOut
        }
        // Drain what's left in the pipe (a grandchild holding it open can't stall us past a second).
        _ = eof.wait(timeout: .now() + 1)
        out.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        if overflow { return .tooLarge }
        guard p.terminationReason == .exit, p.terminationStatus == 0 else { return .failed }
        return .output(String(decoding: data, as: UTF8.self))
    }
}
