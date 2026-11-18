import SwiftUI
import AppKit
import FlightDeckCore

// Disk Space › "What's using my disk": state for the startup-disk breakdown and the space-hog analysis, shared across
// re-creations of the page so an analysis survives switching away. Folder sizes are only measured after the user
// presses Analyze; every cleanup needs a confirmation that lists what goes. In demo mode everything is invented and no
// cleanup can run.

/// A cleanup waiting for the user's confirmation, with exactly what it will do.
enum PendingCleanup: Identifiable {
    case trash(CleanupPlan)
    case emptyTrash(known: UInt64?)
    case simctl(unavailable: [SimDevice])
    case brew(dryRun: String, paths: [String], estimate: String?)
    var id: String {
        switch self {
        case .trash(let p): "trash-" + p.category.id
        case .emptyTrash: "emptyTrash"
        case .simctl: "simctl"
        case .brew: "brew"
        }
    }
}

/// What a finished cleanup achieved, measured afterwards.
struct CleanupReport: Identifiable {
    let id = UUID()
    var title: String
    var lines: [String]
}

@MainActor
final class StorageModel: ObservableObject {
    static let shared = StorageModel()
    @Published var breakdown: Result<StorageBreakdown, StorageReadError>?
    @Published var loadingBreakdown = false
    /// Results in catalog order, as each category finishes.
    @Published var results: [HogResult] = []
    @Published var analyzing = false
    /// Index into the catalog of the category being measured.
    @Published var current = 0
    @Published var pending: PendingCleanup?
    @Published var working: String?
    @Published var report: CleanupReport?
    /// Rows the user expanded.
    @Published var expanded: Set<String> = []
    let catalog = SpaceHogCategory.catalog
    private let live = GenerationBox()
    private var generation = 0
    /// Set for headless demo renders (UIBench), where the app-wide demo flag is off.
    var forceDemo = false
    var demo: Bool { forceDemo || Demo.isEnabled }

    init() {}
    /// A ready-made model for headless renders: demo data, or this Mac's breakdown with optional results.
    init(preview demo: Bool, breakdown: Result<StorageBreakdown, StorageReadError>?, results: [HogResult], expanded: Set<String> = []) {
        forceDemo = demo; self.breakdown = breakdown; self.results = results; self.expanded = expanded
    }

    /// The breakdown only runs diskutil and tmutil (no folder access, no prompts), so it loads when the page opens.
    func loadBreakdown(force: Bool = false) {
        guard !loadingBreakdown, force || breakdown == nil else { return }
        if demo { breakdown = .success(Demo.storageBreakdown()); return }
        loadingBreakdown = true
        Task {
            breakdown = await Task.detached(priority: .userInitiated) { StorageBreakdownReader.read() }.value
            loadingBreakdown = false
        }
    }

    /// Measures every category, streaming results in. Pressing it again (or Cancel) abandons the run in flight.
    func analyze() {
        generation += 1; let gen = generation; live.set(gen)
        results = []; current = 0; analyzing = true; report = nil
        if demo { results = Demo.hogResults(); analyzing = false; return }
        let liveGen = live, owner = WeakBox(self)
        Task.detached(priority: .utility) {
            SpaceHogScanner.analyze(progress: { i in
                DispatchQueue.main.async { if let s = owner.value, s.generation == gen { s.current = i } }
            }, result: { r in
                DispatchQueue.main.async { if let s = owner.value, s.generation == gen { s.results.append(r) } }
            }, cancelled: { liveGen.get() != gen })
            await MainActor.run { if let s = owner.value, s.generation == gen { s.analyzing = false } }
        }
    }

    func cancel() { generation += 1; live.set(generation); analyzing = false }

    func result(_ id: String) -> HogResult? { results.first { $0.category.id == id } }

    // MARK: Preparing a cleanup (nothing changes until the user confirms)

    func prepare(_ r: HogResult) {
        guard !demo else { return }
        switch r.category.cleanup {
        case .trashContents, .trashOlderThan, .trashItems: pending = .trash(CleanupPlanner.plan(r))
        case .emptyTrashViaFinder: pending = .emptyTrash(known: r.total)
        case .simctlDeleteUnavailable:
            working = "Asking simctl…"
            Task {
                let devs = await Task.detached { () -> [SimDevice]? in
                    guard let s = DevTools.simctlPath(), let out = DevTools.run(s, ["list", "-j", "devices"], timeout: 60) else { return nil }
                    return SimctlParse.devices(Data(out.output.utf8))
                }.value
                working = nil
                if let devs { pending = .simctl(unavailable: devs.filter { !$0.isAvailable }) }
                else { report = CleanupReport(title: "Simulator devices", lines: ["simctl isn't available, so nothing was done."]) }
            }
        case .brewCleanup:
            working = "Running brew cleanup -n (dry run)…"
            Task {
                let out = await Task.detached { DevTools.brewPath().flatMap { DevTools.run($0, ["cleanup", "-n"], env: DevTools.brewEnv, timeout: 120) } }.value
                working = nil
                guard let out else { report = CleanupReport(title: "Homebrew", lines: ["brew isn't installed, so nothing was done."]); return }
                pending = .brew(dryRun: out.output, paths: BrewParse.dryRunPaths(out.output), estimate: BrewParse.dryRunEstimate(out.output))
            }
        case .manual: break
        }
    }

    // MARK: Running a confirmed cleanup

    /// Runs `p` off the main thread, then re-measures the category so the report shows the size before and after,
    /// and for the tools that delete (Finder, simctl, brew) also the startup disk's free space before and after.
    func confirm(_ p: PendingCleanup, categoryID: String) {
        pending = nil
        guard !demo, let before = result(categoryID) else { return }
        working = "Cleaning up \(before.category.title)…"
        Task {
            let freeBefore = Self.freeSpace()
            let lines: [String] = await Task.detached(priority: .userInitiated) { Self.run(p) }.value
            let after = await Task.detached(priority: .userInitiated) {
                SpaceHogScanner.measure(before.category, home: NSHomeDirectory(), cancelled: { false })
            }.value
            var out = lines
            out.append("\(before.category.title): \(Self.label(before)) before, \(after.map(Self.label) ?? "not measured") now.")
            if case .trash = p {
                out.append("Moved items stay in the Trash, where you can put them back; the space is freed when the Trash is emptied.")
            } else if let a = freeBefore, let b = Self.freeSpace() {
                let d = Int64(b) - Int64(a)
                out.append("Startup disk free space: \(Fmt.storage(a)) before, \(Fmt.storage(b)) now (\(d >= 0 ? "+" : "−")\(Fmt.storage(UInt64(abs(d))))). Other apps writing at the same time affect this too.")
            }
            if let after, let i = results.firstIndex(where: { $0.category.id == categoryID }) { results[i] = after }
            working = nil
            report = CleanupReport(title: before.category.title, lines: out)
            loadBreakdown(force: true)
        }
    }

    /// Does the work; returns report lines. Called on a background thread.
    nonisolated static func run(_ p: PendingCleanup) -> [String] {
        switch p {
        case .trash(let plan):
            let o = CleanupPlanner.execute(plan)
            var lines = ["Moved \(o.moved.count) item\(o.moved.count == 1 ? "" : "s") (\(Fmt.storage(o.bytesMoved))) to the Trash."]
            lines += o.failed.prefix(8).map { "Not moved: \(($0.path as NSString).lastPathComponent): \($0.reason)" }
            if o.failed.count > 8 { lines.append("…and \(o.failed.count - 8) more not moved.") }
            return lines
        case .emptyTrash:
            // Finder does the emptying, as its own menu item would. macOS asks once for permission to control Finder.
            // osascript rather than NSAppleScript, which isn't safe to use off the main thread.
            guard let r = DevTools.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"], timeout: 600) else { return ["osascript couldn't be run."] }
            return [r.status == 0 ? "Finder emptied the Trash." : "Finder didn't empty the Trash: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))"]
        case .simctl:
            guard let s = DevTools.simctlPath(), let r = DevTools.run(s, ["delete", "unavailable"], timeout: 300) else { return ["simctl couldn't be run."] }
            return [r.status == 0 ? "simctl deleted the unavailable simulators." : "simctl failed: \(r.output.prefix(300))"]
        case .brew:
            guard let b = DevTools.brewPath(), let r = DevTools.run(b, ["cleanup"], env: DevTools.brewEnv, timeout: 600) else { return ["brew couldn't be run."] }
            let tail = r.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            return [r.status == 0 ? "brew cleanup finished. \(tail)" : "brew cleanup failed: \(r.output.prefix(300))"]
        }
    }

    nonisolated static func freeSpace() -> UInt64? {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map { UInt64(max($0, 0)) }
    }

    /// A category's size as text, never a made-up 0.
    nonisolated static func label(_ r: HogResult) -> String {
        if r.isAbsent { return "none" }
        guard let t = r.total else { return "not readable" }
        return (r.isPartial ? "at least " : "") + Fmt.storage(t)
    }

    func reveal(_ path: String) {
        guard !demo else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
}
