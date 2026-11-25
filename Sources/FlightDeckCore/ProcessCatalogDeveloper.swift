import Foundation

enum ProcessCatalogDeveloper {
    static let part: [ProcessExplanation] = [
        ProcessExplanation(
            id: "dev-iterm2", title: "iTerm2",
            summary: "iTerm2, a terminal app that replaces macOS's Terminal.",
            maker: .vendor("George Nachman"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
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
        ProcessExplanation(
            id: "dev-docker-desktop", title: "Docker Desktop",
            summary: "Docker Desktop, Docker's app for building, sharing and running containerised applications on the Mac.",
            maker: .vendor("Docker"),
            busyWhen: nil,
            quit: .avoid, whatToDo: nil,
            findingNote: "Docker Desktop is busy.",
            pathPrefixes: ["/Applications/Docker.app/"], bundleIDs: ["com.docker.docker"], teamIDs: ["9BNSXJN65R"],
            groundedIn: "https://docs.docker.com/desktop/; file:///Applications/Docker.app"),
        ProcessExplanation(
            id: "dev-docker-desktop-app", title: "Docker Desktop's window",
            summary: "The Docker Desktop app's own interface. Your containers run in the separate backend and virtual machine inside Docker.app.",
            maker: .vendor("Docker"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Docker Desktop's interface is busy, rather than a container.",
            pathPrefixes: ["/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/"], teamIDs: ["9BNSXJN65R"],
            groundedIn: "https://docs.docker.com/desktop/; file:///Applications/Docker.app/Contents/MacOS/Docker%20Desktop.app"),
    ]
}
