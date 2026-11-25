// PENDING USER REVIEW: batch 11/12, Developer tools and terminals
import Foundation

enum ProcessCatalogDeveloper {
    static let part: [ProcessExplanation] = [
        ProcessExplanation(
            id: "dev-iterm2", title: "iTerm2",
            summary: "iTerm2, a terminal app that replaces macOS's Terminal.",
            maker: .vendor("George Nachman"),
            busyWhen: nil,
            quit: .avoid, whatToDo: nil,
            findingNote: "iTerm2 itself is busy, rather than a command running in it.",
            names: ["iTerm2"], pathPrefixes: ["/Applications/iTerm.app/"],
            bundleIDs: ["com.googlecode.iterm2"], teamIDs: ["H7V7XYVQ7D"],
            groundedIn: "https://iterm2.com/; file:///Applications/iTerm.app"),
        ProcessExplanation(
            id: "flightdeck", title: "FlightDeck",
            summary: "FlightDeck, the task manager and system monitor you're using. Quitting it stops its monitoring, alerts and rules.",
            maker: .vendor("FlightDeck"),
            busyWhen: nil,
            quit: .avoid, whatToDo: nil,
            findingNote: "FlightDeck itself is busy.",
            names: ["FlightDeck", "Flightdeck"], pathPrefixes: ["/Applications/FlightDeck.app/"],
            groundedIn: "https://github.com/cemeyer2/flightdeck"),
    ]
}
