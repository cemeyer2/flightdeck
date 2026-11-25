import Foundation
// Every sentence the catalog adds to the app, findings and MCP, built here so it is tested without the UI. The app's
// views only render these strings.

public extension ProcessExplanation.QuitSafety {
    /// The inspector's "Quitting it" line.
    var sentence: String {
        switch self {
        case .safe: return "Safe to quit. It starts again when it's needed."
        case .relaunches: return "macOS starts it again within seconds, so quitting it doesn't help."
        case .avoid: return "Quitting it interrupts something you'll notice, such as sound, sync or your display."
        case .never: return "Don't. It's part of macOS, and quitting it can log you out, freeze or restart the Mac."
        }
    }
}

public enum ProcessCatalogText {
    public static let managedLabel = "Managed by your organisation"
    public static let managedAction = "This is managed by your organisation. If it stays busy, contact your IT team."
    public static let noDescription = "FlightDeck has no description of this process."
    public static let nameOnly = "(matched by name only)"
    /// A Processes row's tooltip for another user's process, whose path and some values can't be read.
    public static let restricted = "Owned by another user; some values are unavailable without elevated rights"

    /// CPU and GPU findings: the entry's note followed by an action line, or `defaultAction` alone when the match isn't
    /// known. The note is added, never a replacement: a known process keeps an action line, and a managed one is never
    /// told to quit.
    public static func findingDetail(_ m: ProcessMatch, defaultAction: String) -> String {
        guard let e = m.known else { return defaultAction }
        let action: String
        if e.managed { action = managedAction }
        else {
            switch e.quit {
            case .safe, .avoid: action = defaultAction
            case .relaunches: action = e.whatToDo ?? "Quitting it won't help: macOS starts it again within seconds."
            case .never: action = e.whatToDo ?? "Quitting it won't help: it's part of macOS, and quitting it can log you out or freeze the Mac."
            }
        }
        return e.findingNote + " " + action
    }

    /// Disk and network findings, which carry no action line: the note only, nil when the match isn't known.
    public static func findingNote(_ m: ProcessMatch) -> String? { m.known?.findingNote }

    /// A Processes row's tooltip. Known: "title — summary" (plus "(matched by name only)"), then today's path line, then
    /// the managed label for managed entries. A lookalike or unknown process gets today's text exactly.
    public static func rowTooltip(_ m: ProcessMatch, _ s: ProcessSample) -> String {
        let base = s.restricted ? restricted : s.path
        guard case .known(let e, _, let verified) = m else { return base }
        var t = "\(e.title) — \(e.summary)" + (verified ? "" : " " + nameOnly) + "\n" + base
        if e.managed { t += "\n" + managedLabel }
        return t
    }

    /// The inspector's note for a lookalike (shown nowhere else): what it's named like and where it actually is.
    public static func lookalikeSentence(_ e: ProcessExplanation, path: String) -> String {
        let home = NSHomeDirectory()
        let shown = !home.isEmpty && path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        let owner = e.isApple ? "macOS" : e.makerName
        let keeps = e.isApple ? "where macOS keeps it" : "where \(owner) installs it"
        return "Named like \(owner)'s \(e.names.first ?? e.title) (\(e.title)), but it isn't \(keeps): \(shown)."
    }

    /// The inspector's "What is this?" rows, in order, omitting any without a value. Managed entries show the IT advice
    /// in place of the quitting line.
    public static func inspectorRows(_ e: ProcessExplanation) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [("Maker", e.managed ? "\(e.makerName) · \(managedLabel)" : e.makerName)]
        if let b = e.busyWhen { rows.append(("Usually busy when", b)) }
        if e.managed {
            rows.append(("If it stays busy", e.whatToDo ?? managedAction))
        } else {
            rows.append(("Quitting it", e.quit.sentence))
            if let w = e.whatToDo { rows.append(("If it misbehaves", w)) }
        }
        return rows
    }
}

/// What FlightDeck already knows about a process the catalog doesn't describe (or one that only looks like a
/// catalogued program). Facts only, never invented text.
public enum ProcessFacts {
    /// Signer, Team, App, Launched by (a launchd job or login item whose program is this path, otherwise the parent
    /// from the ancestry), Parent (when the launcher came from a job, so the parent isn't lost), then the explicit
    /// "no description" line. `ancestry` starts with the process itself, as `ProcessDetails.ancestry` does.
    public static func lines(_ s: ProcessSample, signature: ProcessDetails.Signature?, ancestry: [(pid: Int32, name: String)],
                             startupItems: [StartupItem]) -> [(label: String, value: String)] {
        var out: [(label: String, value: String)] = []
        if let sig = signature {
            out.append(("Signer", sig.summary))
            if let t = sig.teamID { out.append(("Team", t)) }
        }
        if let b = AppUsage.bundle(of: s.path) { out.append(("App", ((b as NSString).lastPathComponent as NSString).deletingPathExtension)) }
        let parent = ancestry.count > 1 ? "\(ancestry[1].name) (\(ancestry[1].pid))" : nil
        if !s.path.isEmpty, let job = startupItems.first(where: { $0.program == s.path }) {
            out.append(("Launched by", "\(job.label) (\(job.kind))"))
            if let p = parent { out.append(("Parent", p)) }
        } else if let p = parent {
            out.append(("Launched by", "parent \(p)"))
        }
        out.append(("Description", ProcessCatalogText.noDescription))
        return out
    }
}
