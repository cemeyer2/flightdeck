// PENDING USER REVIEW: batch 2/12, iCloud, sync and file providers
import Foundation

enum ProcessCatalogCloud {
    static let part: [ProcessExplanation] = [
        ProcessExplanation(
            id: "icloud-bird", title: "iCloud Drive daemon",
            summary: "One of the system daemons behind iCloud Drive (Documents in the Cloud).",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "iCloud is syncing files.",
            names: ["bird"],
            groundedIn: "x-man-page://8/bird; file:///System/Library/LaunchAgents/com.apple.bird.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "icloud-cloudd", title: "CloudKit daemon",
            summary: "The system daemon behind CloudKit, which apps use to store and sync their data in iCloud.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "iCloud is syncing app data.",
            names: ["cloudd"],
            groundedIn: "x-man-page://8/cloudd; https://developer.apple.com/documentation/cloudkit; file:///System/Library/LaunchAgents/com.apple.cloudd.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "icloud-fileproviderd", title: "File provider daemon",
            summary: "Connects file provider extensions, which apps use to sync folders with online storage, to the rest of macOS. It also lists their files and looks up file details.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "iCloud Drive or another cloud storage app is syncing files.",
            names: ["fileproviderd"],
            groundedIn: "x-man-page://8/fileproviderd; https://developer.apple.com/documentation/fileprovider; file:///System/Library/LaunchAgents/com.apple.FileProvider.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "nsurlsessiond", title: "Background transfer daemon",
            summary: "Performs the background downloads and uploads that apps and macOS services hand to the system.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "An app or macOS is downloading or uploading in the background, for example iCloud syncing files.",
            names: ["nsurlsessiond"],
            groundedIn: "x-man-page://8/nsurlsessiond; file:///System/Library/LaunchAgents/com.apple.nsurlsessiond.plist; x-man-page://5/launchd.plist"),
    ]
}
