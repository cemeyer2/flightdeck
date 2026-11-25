import Foundation

/// The catalog's part files, one per review batch of about 50 entries grouped by area. Each part is its own typed
/// literal so the compiler never has to type-check one giant table.
enum ProcessCatalogParts {
    struct Batch { let number: Int; let area: String; let entries: [ProcessExplanation] }

    static let batches: [Batch] = [
        Batch(number: 1, area: "Spotlight, search, Siri and suggestions", entries: ProcessCatalogSpotlight.part),
        Batch(number: 2, area: "iCloud, sync and file providers", entries: ProcessCatalogCloud.part),
        Batch(number: 3, area: "Photos, media, audio, camera", entries: ProcessCatalogMedia.part),
        Batch(number: 4, area: "Window server, Finder, Dock, desktop", entries: ProcessCatalogDesktop.part),
        Batch(number: 5, area: "macOS security, privacy, code signing", entries: ProcessCatalogSecurity.part),
        Batch(number: 6, area: "Kernel, launchd, power, logging", entries: ProcessCatalogCore.part),
        Batch(number: 7, area: "Networking, Bluetooth, Continuity", entries: ProcessCatalogNetwork.part),
        Batch(number: 8, area: "Updates, backups, storage", entries: ProcessCatalogUpdates.part),
        Batch(number: 9, area: "Browsers and web content", entries: ProcessCatalogBrowsers.part),
        Batch(number: 10, area: "Sync, meetings, productivity apps", entries: ProcessCatalogApps.part),
        Batch(number: 11, area: "Developer tools and terminals", entries: ProcessCatalogDeveloper.part),
        Batch(number: 12, area: "Corporate security and MDM (managed)", entries: ProcessCatalogManaged.part),
    ]

    static let all: [ProcessExplanation] = batches.flatMap(\.entries)
}
