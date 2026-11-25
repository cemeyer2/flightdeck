// PENDING USER REVIEW: batch 4/12, Window server, Finder, Dock, desktop
import Foundation

enum ProcessCatalogDesktop {
    static let part: [ProcessExplanation] = [
        ProcessExplanation(
            id: "desktop-windowserver", title: "Window server",
            summary: "Draws everything on screen: it manages windows, combines every app's content into what the displays show, and routes keyboard and mouse events.",
            maker: .apple,
            busyWhen: "With many windows, several displays, or lots of animation.",
            quit: .never, whatToDo: nil,
            findingNote: "WindowServer draws everything on screen. It rises with many windows, displays, or animations.",
            names: ["WindowServer"],
            groundedIn: "x-man-page://8/WindowServer; file:///System/Library/LaunchDaemons/com.apple.WindowServer.plist"),
        ProcessExplanation(
            id: "desktop-loginwindow", title: "Login window and session",
            summary: "Handles logging in, sets up your session, and then watches over it. It manages logging out, restarting and shutting down.",
            maker: .apple,
            busyWhen: nil,
            quit: .never, whatToDo: nil,
            findingNote: "loginwindow manages your login session.",
            names: ["loginwindow"],
            groundedIn: "https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/Lifecycle.html; file:///System/Library/LaunchDaemons/com.apple.loginwindow.plist"),
        ProcessExplanation(
            id: "desktop-finder", title: "Finder",
            summary: "The Finder, where you view, open and organise almost everything on your Mac.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "The Finder is busy.",
            names: ["Finder"],
            groundedIn: "https://support.apple.com/guide/mac-help/organize-your-files-in-the-finder-mchlp2605/mac; file:///System/Library/LaunchAgents/com.apple.Finder.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "desktop-dock", title: "Dock",
            summary: "Provides the Dock.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "The Dock is busy.",
            names: ["Dock"],
            groundedIn: "x-man-page://8/Dock; file:///System/Library/LaunchAgents/com.apple.Dock.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "desktop-systemuiserver", title: "Menu bar status items",
            summary: "Shows status items in the right side of the menu bar.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "SystemUIServer shows menu bar status items.",
            names: ["SystemUIServer"],
            groundedIn: "x-man-page://8/SystemUIServer; file:///System/Library/LaunchAgents/com.apple.SystemUIServer.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "desktop-controlcenter", title: "Control Center",
            summary: "Control Center, which provides system controls in the menu bar.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "Control Center runs the system controls in the menu bar.",
            names: ["ControlCenter"],
            groundedIn: "x-man-page://8/ControlCenter; file:///System/Library/LaunchAgents/com.apple.controlcenter.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "desktop-terminal", title: "Terminal",
            summary: "Apple's Terminal app, for working with shells, command-line tools and scripts.",
            maker: .apple,
            busyWhen: nil,
            quit: .avoid, whatToDo: nil,
            findingNote: "Terminal itself is busy, rather than a command running in it.",
            names: ["Terminal"], pathPrefixes: ["/System/Applications/Utilities/Terminal.app/"],
            groundedIn: "https://support.apple.com/guide/terminal/welcome/mac; file:///System/Applications/Utilities/Terminal.app"),
    ]
}
