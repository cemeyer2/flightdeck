// PENDING USER REVIEW: batch 1/12, Spotlight, search, Siri and suggestions
import Foundation

enum ProcessCatalogSpotlight {
    static let part: [ProcessExplanation] = [
        ProcessExplanation(
            id: "spotlight-mds", title: "Spotlight metadata server",
            summary: "The metadata server behind Spotlight. It serves every app that searches or reads file metadata, and uses worker processes to index your files.",
            maker: .apple,
            busyWhen: "When a disk is connected or many files change, such as after a big copy or a macOS update.",
            quit: .relaunches, whatToDo: nil,
            findingNote: "Spotlight is indexing files. It finishes on its own, usually after big copies or updates.",
            names: ["mds"],
            groundedIn: "x-man-page://8/mds; x-man-page://8/mdworker; file:///System/Library/LaunchDaemons/com.apple.metadata.mds.plist"),
        ProcessExplanation(
            id: "spotlight-mds-stores", title: "Spotlight index store",
            summary: "Keeps Spotlight's index up to date on behalf of mds, the metadata server.",
            maker: .apple,
            busyWhen: "When a disk is connected or many files change, such as after a big copy or a macOS update.",
            quit: .relaunches, whatToDo: nil,
            findingNote: "Spotlight is updating its index. It finishes on its own, usually after big copies or updates.",
            names: ["mds_stores"],
            groundedIn: "x-man-page://8/mds; x-man-page://8/mdworker; file:///System/Library/LaunchDaemons/com.apple.metadata.mds.index.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "spotlight-mdworker", title: "Spotlight indexing worker",
            summary: "Reads files so Spotlight can index them. The metadata server, mds, starts these workers as needed.",
            maker: .apple,
            busyWhen: "When a disk is connected or files change, such as after a big copy or a macOS update.",
            quit: .relaunches, whatToDo: nil,
            findingNote: "Spotlight is indexing files. It finishes on its own, usually after big copies or updates.",
            names: ["mdworker", "mdworker_shared"],
            groundedIn: "x-man-page://8/mdworker; file:///System/Library/LaunchAgents/com.apple.mdworker.shared.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "spotlight-mdsync", title: "Spotlight volume scanner",
            summary: "Scans disks for Spotlight's metadata server, mds.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "Spotlight is scanning a disk. It finishes on its own.",
            names: ["mdsync"],
            groundedIn: "x-man-page://8/mds; file:///System/Library/LaunchDaemons/com.apple.metadata.mds.scan.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "spotlight-corespotlightd", title: "Spotlight app content indexer",
            summary: "Indexes content that apps add to Spotlight through Core Spotlight, so you can find it from Spotlight and Safari.",
            maker: .apple,
            busyWhen: "When apps add or change content in Spotlight, and in daily background maintenance.",
            quit: .relaunches, whatToDo: nil,
            findingNote: "macOS is updating Siri and Spotlight suggestions.",
            names: ["corespotlightd"],
            groundedIn: "https://developer.apple.com/documentation/corespotlight; file:///System/Library/LaunchAgents/com.apple.corespotlightd.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "siri-suggestd", title: "Siri suggestions",
            summary: "Reads content from Spotlight, Mail, Messages and other apps to find contacts, events and other details. This powers Found in Apps, QuickType suggestions and Siri personalisation.",
            maker: .apple,
            busyWhen: "In scheduled background maintenance, most of it daily and only while the Mac is on power.",
            quit: .relaunches, whatToDo: nil,
            findingNote: "macOS is updating Siri and Spotlight suggestions.",
            names: ["suggestd"],
            groundedIn: "x-man-page://8/suggestd; file:///System/Library/LaunchAgents/com.apple.suggestd.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "siri-knowledge-agent", title: "Siri suggestions knowledge agent",
            summary: "Part of Siri suggestions. It responds as app interactions are recorded and answers suggestion requests, such as calendar and reminder suggestions.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "macOS is updating Siri and Spotlight suggestions.",
            names: ["knowledge-agent"],
            groundedIn: "file:///System/Library/LaunchAgents/com.apple.knowledge-agent.plist; x-man-page://5/launchd.plist"),
    ]
}
