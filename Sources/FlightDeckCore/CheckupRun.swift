import Foundation
import IOKit

// The I/O half of Checkup: runs each tool or reads each plist, then hands the raw output to CheckupRules. Called only
// when the Checkup page opens or Refresh is pressed; `softwareupdate --list` (slow, contacts Apple) only on its button.

public enum Checkup {
    /// Runs every check, in parallel (each one is a separate tool or file), and returns them in display order.
    /// `swapHistory` is (time, swap bytes used) from the black box, oldest first; pass [] when there is none.
    /// `liveUpdates` is the result of a previous `softwareUpdateCheck()`, if the user ran one. Blocking; call off the main thread.
    public static func run(swapHistory: [(Date, Double)], liveUpdates: [String]? = nil, liveUpdateError: String? = nil) -> [CheckResult] {
        let updatePrefs = plist("/Library/Managed Preferences/com.apple.SoftwareUpdate.plist")
            .map { managed in (plist("/Library/Preferences/com.apple.SoftwareUpdate.plist") ?? [:]).merging(managed) { _, m in m } }
            ?? plist("/Library/Preferences/com.apple.SoftwareUpdate.plist")
        let prefs = updatePrefs.map(CheckupParse.updatePrefs)
        let jobs: [@Sendable () -> CheckResult] = [
            { CheckupRules.sip(Shell.run("/usr/bin/csrutil", ["status"])) },
            { CheckupRules.fileVault(Shell.run("/usr/bin/fdesetup", ["status"])) },
            { CheckupRules.gatekeeper(Shell.run("/usr/sbin/spctl", ["--status"])) },
            { let fw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
              return CheckupRules.firewall(state: Shell.run(fw, ["--getglobalstate"]), stealth: Shell.run(fw, ["--getstealthmode"])) },
            { CheckupRules.secureBoot(Shell.run("/usr/sbin/system_profiler", ["-json", "SPiBridgeDataType"], timeout: 20)
                .flatMap { CheckupParse.secureBoot(Data($0.utf8)) }) },
            { CheckupRules.autoUpdates(prefs) },
            { CheckupRules.pendingUpdates(prefs, live: liveUpdates, liveError: liveUpdateError) },
            { timeMachine() },
            { CheckupRules.freeSpace(DiskSampler.volumes().first { $0.path == "/" }) },
            { CheckupRules.drives(DriveHealthReader.read()) },
            { battery() },
            { CheckupRules.reports(DiagnosticReports.scan(since: Date().addingTimeInterval(-7 * 86_400))) },
            { CheckupRules.uptime(boot: Sysctl.timeval("kern.boottime")) },
            { CheckupRules.swap(current: swapUsed(), history: swapHistory, ram: Sysctl.int("hw.memsize").map(Double.init)) },
            { CheckupRules.startupItems(Launchd.startupItems(includeLoginItems: false)) },
            { CheckupRules.kexts(Shell.run("/usr/bin/kmutil", ["showloaded", "--list-only"], timeout: 20)) },
            { CheckupRules.systemExtensions(Shell.run("/usr/bin/systemextensionsctl", ["list"])) },
        ]
        // Each job writes only its own slot; the lock just makes the array writes safe across threads.
        let box = ResultBox(count: jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in box.set(i, jobs[i]()) }
        return box.results
    }

    /// `softwareupdate --list`: asks Apple's servers which updates apply (takes 10-60 s, needs the network, no root).
    /// Returns the update titles, or an error string when the output wasn't recognised (offline, server error).
    public static func softwareUpdateCheck() -> (updates: [String]?, error: String?) {
        guard let out = runMerged("/usr/sbin/softwareupdate", ["--list"], timeout: 120) else { return (nil, "softwareupdate could not be run.") }
        if let list = CheckupParse.softwareUpdateList(out) { return (list, nil) }
        let last = out.split(separator: "\n").last.map(String.init) ?? "no output"
        return (nil, "softwareupdate didn't return a list (\(last)).")
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [CheckResult?]
        init(count: Int) { slots = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ r: CheckResult) { lock.lock(); slots[i] = r; lock.unlock() }
        var results: [CheckResult] { lock.lock(); defer { lock.unlock() }; return slots.compactMap { $0 } }
    }

    static func plist(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
    }

    /// The preferences plist first; `tmutil latestbackup` only if it has no date, since tmutil may try to mount a
    /// network backup disk and take a while.
    static func timeMachine() -> CheckResult {
        let tm = plist("/Library/Preferences/com.apple.TimeMachine.plist").map(CheckupParse.timeMachine)
        var fromTool: Date?
        if tm?.latest == nil, tm?.destinations != 0 {
            fromTool = Shell.run("/usr/bin/tmutil", ["latestbackup"], timeout: 20).flatMap(CheckupParse.tmutilLatest)
        }
        return CheckupRules.timeMachine(tm, tmutil: fromTool)
    }

    /// An AppleSmartBattery node in the IORegistry means the Mac has a battery; system_profiler supplies the condition.
    static func battery() -> CheckResult {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        let has = svc != 0
        if has { IOObjectRelease(svc) }
        let b = has ? Shell.run("/usr/sbin/system_profiler", ["-json", "SPPowerDataType"], timeout: 20).flatMap { CheckupParse.battery(Data($0.utf8)) } : nil
        return CheckupRules.battery(b, hasBattery: has)
    }

    /// vm.swapusage's xsu_used in bytes; nil if the sysctl fails.
    static func swapUsed() -> Double? {
        var swap = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? Double(swap.xsu_used) : nil
    }

    /// Like Shell.run, but with stderr merged into stdout: softwareupdate prints "No new software available." to stderr.
    static func runMerged(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return nil }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // to EOF first, so a full pipe can't deadlock
        p.waitUntilExit(); timer.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}
