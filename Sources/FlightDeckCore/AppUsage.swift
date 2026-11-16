import Foundation

/// Per-app resource use: helpers inside an `.app` bundle roll up to the outermost bundle
/// (…/Chrome.app/…/Helper.app/… → Chrome); everything else is grouped by process name.
public struct AppUsage: Sendable, Identifiable, Hashable {
    public var id: String              // bundle path or "proc:<name>"
    public var name: String
    public var iconPath: String
    public var processes = 0
    public var cpu = 0.0               // % of one core
    public var memory: UInt64 = 0
    public var threads = 0
    public var diskBps = 0.0
    public var netBps = 0.0
    public var energyWatts: Double?    // nil if no member reports energy
    public var wakeups = 0.0
    public var gpu: Double?             // nil if no member uses the GPU
    public var pids: [Int32] = []

    public static func bundle(of path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    public static func key(for p: ProcessSample) -> (key: String, name: String, icon: String) {
        if let b = bundle(of: p.path) {
            return (b, ((b as NSString).lastPathComponent as NSString).deletingPathExtension, b)
        }
        return ("proc:\(p.name)", p.name, p.path)
    }

    /// Group keys aligned with `procs`. A process whose path is unreadable but whose name matches an app
    /// bundle seen in the same sample joins that app (e.g. an app's main process when its path is hidden).
    public static func groupKeys(_ procs: [ProcessSample]) -> [(key: String, name: String, icon: String)] {
        let raw = procs.map(key(for:))
        var byName: [String: (key: String, name: String, icon: String)] = [:]
        for k in raw where !k.key.hasPrefix("proc:") { byName[k.name] = k }
        return raw.map { k in k.key.hasPrefix("proc:") ? (byName[k.name] ?? k) : k }
    }

    public static func aggregate(_ procs: [ProcessSample]) -> [AppUsage] {
        var groups: [String: AppUsage] = [:]
        for (p, k) in zip(procs, groupKeys(procs)) {
            var g = groups[k.key] ?? AppUsage(id: k.key, name: k.name, iconPath: k.icon)
            g.processes += 1; g.cpu += p.cpu; g.memory += p.memory; g.threads += p.threads
            g.diskBps += p.diskReadBps + p.diskWriteBps
            g.netBps += (p.network?.inBps ?? 0) + (p.network?.outBps ?? 0)
            if let e = p.energyWatts { g.energyWatts = (g.energyWatts ?? 0) + e }
            g.wakeups += p.wakeups; g.pids.append(p.pid)
            if let x = p.gpu { g.gpu = (g.gpu ?? 0) + x }
            groups[k.key] = g
        }
        return Array(groups.values)
    }
}

/// Plain-English explanations for well-known macOS background work.
public enum KnownProcess {
    static let table: [(match: [String], text: String)] = [
        (["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync"], "Spotlight is indexing files. It finishes on its own, usually after big copies or updates."),
        (["backupd", "backupd-helper"], "Time Machine is backing up."),
        (["photoanalysisd", "photolibraryd", "mediaanalysisd"], "Photos is analysing your library (faces, scenes). It runs mostly when the Mac is idle or charging."),
        (["softwareupdated", "softwareupdate_download_service", "mobileassetd"], "macOS is downloading or preparing a software update."),
        (["kernel_task"], "kernel_task is macOS itself. High CPU here is often deliberate: it keeps the CPU busy to slow other work and cool the Mac down."),
        (["WindowServer"], "WindowServer draws everything on screen. It rises with many windows, displays, or animations."),
        (["bird", "cloudd", "fileproviderd", "nsurlsessiond"], "iCloud is syncing files."),
        (["XprotectService", "XProtect", "syspolicyd", "trustd"], "macOS is scanning apps for malware or checking signatures."),
        (["corespotlightd", "suggestd", "knowledge-agent"], "macOS is updating Siri and Spotlight suggestions."),
        (["Google Chrome Helper", "Google Chrome Helper (Renderer)"], "Chrome runs each tab and extension as a separate helper process."),
        (["com.apple.WebKit.WebContent"], "A Safari (or WebKit) tab or web view is busy."),
        (["coreaudiod"], "The audio system is busy."),
        (["launchd"], "launchd starts and stops system services."),
    ]
    public static func explain(_ name: String) -> String? {
        table.first { $0.match.contains(name) }?.text
    }
}
