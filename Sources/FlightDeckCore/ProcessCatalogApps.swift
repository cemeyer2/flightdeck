import Foundation

enum ProcessCatalogApps {
    static let part: [ProcessExplanation] = [
        ProcessExplanation(
            id: "apps-zoom", title: "Zoom Workplace",
            summary: "Zoom Workplace, Zoom's app for meetings, chat, docs and more.",
            maker: .vendor("Zoom"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Zoom is busy.",
            pathPrefixes: ["/Applications/zoom.us.app/"], bundleIDs: ["us.zoom.xos"], teamIDs: ["BJ4HAAB9B3"],
            groundedIn: "https://www.zoom.com/en/products/collaboration-tools/; file:///Applications/zoom.us.app"),
        ProcessExplanation(
            id: "apps-1password", title: "1Password",
            summary: "1Password, a vault for your passwords, other credentials and secrets.",
            maker: .vendor("AgileBits"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "1Password is busy.",
            pathPrefixes: ["/Applications/1Password.app/"], bundleIDs: ["com.1password.1password"], teamIDs: ["2BUA8C4S2C"],
            groundedIn: "https://1password.com/; file:///Applications/1Password.app"),
    ]
}
