import Foundation
// Chrome tabs: the text shown for a renderer's tabs, in one place so every view says the same thing and tests can pin
// down what never appears (a tab's address is shown only in the inspector's own tab list). A shared renderer's CPU is
// always shown whole, marked "shared", never divided between its tabs.

/// A renderer row's name, in three parts so only the page title truncates: the host and the suffix always show in full,
/// whatever the page calls itself.
public struct ChromeTabLabel: Sendable, Equatable {
    /// The site, or "Chrome extension process".
    public var host: String
    /// The first tab's sanitised title; nil when it is empty, and for frames and extension processes.
    public var title: String?
    /// "(Chrome tab)", "(Chrome tab) +2 more tabs", "— frame in youtube.com tab", or "" for an extension process.
    public var suffix: String
    /// The parts joined, for places that take one string.
    public var plain: String

    public init?(_ a: ChromeTabAttribution) {
        let tabs = a.entries.filter { $0.kind == .tab }
        if let first = tabs.first {
            host = first.host
            title = first.title.isEmpty ? nil : first.title
            suffix = "(Chrome tab)" + ChromeTabText.more(tabs.count - 1, "tab")
        } else if let f = a.entries.first, case .frame(let inTab) = f.kind {
            host = f.host
            title = nil
            suffix = "— frame in \(inTab) tab" + ChromeTabText.more(a.entries.count - 1, "frame")
        } else if a.isExtensionProcess {
            host = "Chrome extension process"; title = nil; suffix = ""
        } else {
            return nil
        }
        plain = [host, title.map { "— \($0)" }, suffix.isEmpty ? nil : suffix].compactMap { $0 }.joined(separator: " ")
    }
}

public enum ChromeTabText {
    static func more(_ n: Int, _ noun: String) -> String { n > 0 ? " +\(n) more \(noun)\(n == 1 ? "" : "s")" : "" }

    /// "host — title" for a tab (the host alone when untitled), "host — frame in x tab" for a frame.
    static func line(_ e: ChromeTabEntry) -> String {
        switch e.kind {
        case .tab: return e.title.isEmpty ? e.host : "\(e.host) — \(e.title)"
        case .frame(let inTab): return "\(e.host) — frame in \(inTab) tab"
        }
    }

    /// One line per tab and frame, for the name cell's tooltip.
    public static func tooltip(_ a: ChromeTabAttribution) -> String {
        a.entries.isEmpty ? (a.isExtensionProcess ? "Chrome extension process" : "") : a.entries.map(line).joined(separator: "\n")
    }

    /// Hosts and titles, lowercased, for the Processes filter. Kept in memory only, like the filter text itself.
    public static func searchText(_ a: ChromeTabAttribution) -> String {
        (a.entries.flatMap { [$0.host, $0.title] } + (a.isExtensionProcess ? ["chrome extension process"] : []))
            .joined(separator: "\n").lowercased()
    }

    /// The inspector's Copy Summary section: a heading and one indented line per tab and frame, host and title only. A
    /// copy can travel through Universal Clipboard and clipboard history, so the address never goes in. "" when empty.
    public static func summaryLines(_ a: ChromeTabAttribution) -> String {
        guard !a.entries.isEmpty else { return "" }
        return (["Chrome tabs"] + a.entries.map { "  " + line($0) }).joined(separator: "\n")
    }

    /// Added to the quit/kill confirmation: killing a renderer closes every tab in it. Frames aren't counted (their tab
    /// survives, showing a crashed frame). nil when the process holds no tabs.
    public static func killWarning(_ a: ChromeTabAttribution) -> String? {
        let hosts = a.entries.filter { $0.kind == .tab }.map(\.host)
        guard !hosts.isEmpty else { return nil }
        let shown = hosts.prefix(5).joined(separator: ", ") + (hosts.count > 5 ? " and \(hosts.count - 5) more" : "")
        return "This closes \(hosts.count) Chrome tab\(hosts.count == 1 ? "" : "s"): \(shown)"
    }

    /// The extra line under a Chrome CPU finding in the app, e.g.
    /// "Mostly: youtube.com — Lofi (120%), docs.google.com +2 more tabs (40%, shared)". Walks `pids` in order (the
    /// finding lists them busiest first), skips processes without tabs or under 5% CPU, and names at most three. nil
    /// when none qualify. The finding itself (and so notifications and the Flight Log) never carries this text.
    public static func mostlyLine(pids: [Int32], processes: [ProcessSample], attribution: [ProcessIdentity: ChromeTabAttribution]) -> String? {
        guard !attribution.isEmpty else { return nil }
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var parts: [String] = []
        for pid in pids where parts.count < 3 {
            guard let p = byPID[pid], p.cpu >= 5, let a = attribution[p.identity], let label = ChromeTabLabel(a) else { continue }
            let cpu = "\(Int(p.cpu.rounded()))%"
            if a.tabCount > 1 {
                parts.append("\(label.host)\(more(a.tabCount - 1, "tab")) (\(cpu), shared)")
            } else {
                parts.append("\(label.plain.replacingOccurrences(of: " (Chrome tab)", with: "")) (\(cpu))")
            }
        }
        return parts.isEmpty ? nil : "Mostly: " + parts.joined(separator: ", ")
    }
}
