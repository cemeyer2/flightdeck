// Demo mode's What Changed: an invented week on an invented Mac (home folder /Users/demo). A macOS update, a new app,
// an app update, Homebrew upgrades, a new sync app's launch agent and file-provider extension, one unsigned helper
// hiding in a dot-folder, Screen Sharing turned on and off again, and a removed app. Nothing comes from this Mac: the
// invented items go through the real ChangeDiff rules, so reasons and notable flags are what the page would show.
import Foundation
import FlightDeckCore

enum DemoChanges {
    static let home = "/Users/demo"

    static func report(now: Date = Date()) -> ChangesReport {
        let day = 86_400.0
        func at(_ daysAgo: Double, _ hour: Double) -> Date {
            Calendar.current.startOfDay(for: now.addingTimeInterval(-daysAgo * day)).addingTimeInterval(hour * 3600)
        }
        var events: [ChangeEvent] = []
        /// A change found by the check at `t`, with the item's modification time `mtime` minutes before it.
        func add(_ kind: ChangeEvent.Kind, _ item: InventoryItem, _ previous: InventoryItem? = nil, at t: Date, mtime: Double? = nil, boot: Date? = nil) {
            var item = item
            if let mtime { item.modified = t.addingTimeInterval(-mtime * 60) }
            let old = Inventory(time: t.addingTimeInterval(-900), items: [])
            let new = Inventory(time: t, items: [], boot: boot)
            guard t < now else { return }
            events.append(ChangeDiff.event(kind, item, previous, old: old, new: new, home: home))
        }
        let os1 = InventoryItem(category: .macOS, key: "macOS", name: "macOS", version: "26.1 (25B78)")
        var os2 = os1; os2.version = "26.2 (25C56)"
        let t6 = at(6, 9.25)
        add(.updated, os2, os1, at: t6, boot: t6.addingTimeInterval(-11 * 60))

        add(.added, app("Clipboard Keeper", "2.4.1", id: "com.keeperapps.clipboard", team: "K7P2XQ9M4D", vendor: "Keeper Apps Ltd"), at: at(5, 14.6), mtime: 6)
        let brewOld = brew("jq", "1.7.1"), brewNew = brew("jq", "1.8.0")
        add(.updated, brewNew, brewOld, at: at(4, 11.1), mtime: 3)
        add(.added, brew("ripgrep", "14.1.1"), at: at(4, 11.1), mtime: 2)
        add(.updated, app("Photo Editor", "5.2", id: "com.lumenlabs.photoeditor", team: "L4M8N2B6C1", vendor: "Lumen Labs Inc."),
            app("Photo Editor", "5.1.3", id: "com.lumenlabs.photoeditor", team: "L4M8N2B6C1", vendor: "Lumen Labs Inc."), at: at(3, 10.4), mtime: 9)
        add(.added, app("CloudSyncr", "3.0", id: "com.cloudsyncr.app", team: "C9S3R7Y2N5", vendor: "CloudSyncr GmbH"), at: at(3, 16.2), mtime: 4)
        add(.added, agent("com.cloudsyncr.agent", program: "/Applications/CloudSyncr.app/Contents/Library/LoginItems/CloudSyncr Agent.app/Contents/MacOS/CloudSyncr Agent",
                          signer: "Developer ID Application: CloudSyncr GmbH (C9S3R7Y2N5)", sig: .developer), at: at(3, 16.2), mtime: 3)
        add(.added, InventoryItem(category: .systemExtension, key: "com.cloudsyncr.app.fileprovider", name: "CloudSyncr File Provider", version: "3.0/112",
                                  state: "activated enabled", teamID: "C9S3R7Y2N5", bundleID: "com.cloudsyncr.app.fileprovider"), at: at(3, 16.45))
        add(.added, agent("com.freepdf-tools.update", program: home + "/Library/Application Support/.pdfhelper/pdfupd", signer: "Not signed", sig: .unsigned),
            at: at(2, 20.75), mtime: 12)
        let off = sharing("Screen Sharing", on: false), on = sharing("Screen Sharing", on: true)
        add(.modified, on, off, at: at(1, 13.0))
        add(.modified, off, on, at: at(1, 15.5))
        add(.removed, app("Puzzle Quest Classic", "1.9", id: "com.example-games.pqc", team: "G5H6J7K8L9", vendor: "Example Games"), at: at(0, 8.3))

        return ChangesReport(events: events.sorted { $0.when > $1.when }, baseline: at(13, 9.5), lastCheck: now.addingTimeInterval(-7 * 60), inventory: inventory(now))
    }

    static func app(_ name: String, _ v: String, id: String, team: String, vendor: String) -> InventoryItem {
        InventoryItem(category: .app, key: "/Applications/\(name).app", name: name, version: v, path: "/Applications/\(name).app",
                      signer: "Signed: Developer ID Application: \(vendor) (\(team))", teamID: team, signature: .developer, bundleID: id)
    }

    static func agent(_ label: String, program: String, signer: String, sig: SignatureState) -> InventoryItem {
        let path = home + "/Library/LaunchAgents/\(label).plist"
        return InventoryItem(category: .launchItem, key: path, name: label, scope: "Launch Agent (User)", path: path, program: program,
                             signer: signer, teamID: sig == .developer ? String(signer.suffix(11).dropLast()) : nil, signature: sig, runsAtLoad: true)
    }

    static func brew(_ name: String, _ v: String) -> InventoryItem {
        InventoryItem(category: .homebrew, key: "formula:\(name)", name: name, version: v, scope: "formula", path: "/opt/homebrew/Cellar/\(name)/\(v)")
    }

    static func sharing(_ name: String, on: Bool) -> InventoryItem {
        InventoryItem(category: .sharing, key: "com.apple.screensharing", name: name, scope: "launchd job com.apple.screensharing", state: on ? "On" : "Off")
    }

    /// An invented current inventory, for the "What's tracked" counts.
    static func inventory(_ now: Date) -> Inventory {
        let counts: [(ChangeCategory, Int)] = [(.macOS, 1), (.launchItem, 23), (.systemExtension, 1), (.profile, 2), (.sharing, 5), (.app, 64), (.homebrew, 87)]
        var items = counts.flatMap { c, n in (0..<n).map { InventoryItem(category: c, key: "demo-\(c.rawValue)-\($0)", name: "demo \($0)") } }
        items[0].version = "26.2 (25C56)"
        for k in items.indices where items[k].category == .profile { items[k].key = k % 2 == 0 ? "enrollment:MDM enrollment" : "enrollment:Enrolled via DEP"; items[k].state = "No" }
        for k in items.indices where items[k].category == .sharing { items[k].state = "Off" }
        return Inventory(time: now.addingTimeInterval(-7 * 60), items: items,
                         limits: ["Login items and apps' background items (System Settings › Login Items) aren't listed: reading them needs Automation permission or root. Launch agents and daemons are.",
                                  "Configuration profiles installed for the whole Mac can only be listed with root; FlightDeck shows your user's profiles, MDM enrollment and the managed-settings domains they create in /Library/Managed Preferences."])
    }
}
