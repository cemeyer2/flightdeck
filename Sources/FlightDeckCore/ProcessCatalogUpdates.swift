// PENDING USER REVIEW: batch 8/12, Updates, backups, storage
import Foundation

enum ProcessCatalogUpdates {
    static let part: [ProcessExplanation] = [
        ProcessExplanation(
            id: "updates-softwareupdated", title: "Software Update daemon",
            summary: "The main daemon that runs macOS software updates.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "macOS is downloading or preparing a software update.",
            names: ["softwareupdated"],
            groundedIn: "x-man-page://8/softwareupdated; file:///System/Library/LaunchDaemons/com.apple.softwareupdated.plist; file:///System/Library/LaunchDaemons/com.apple.mobile.softwareupdated.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "updates-mobileassetd", title: "Downloadable system assets",
            summary: "Downloads and manages parts of macOS delivered separately from the system, such as fonts, dictionaries, voices and software update files.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "macOS is downloading or preparing system assets, such as fonts, voices or a software update.",
            names: ["mobileassetd"],
            groundedIn: "file:///System/Library/LaunchDaemons/com.apple.mobileassetd.plist; file:///System/Library/AssetsV2; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "backup-backupd", title: "Time Machine backup",
            summary: "The Time Machine daemon. It makes your Time Machine backups and manages the backup history.",
            maker: .apple,
            busyWhen: "While a Time Machine backup is running.",
            quit: .avoid, whatToDo: nil,
            findingNote: "Time Machine is backing up.",
            names: ["backupd"],
            groundedIn: "x-man-page://8/backupd; file:///System/Library/LaunchDaemons/com.apple.backupd.plist"),
        ProcessExplanation(
            id: "backup-backupd-helper", title: "Time Machine scheduler",
            summary: "Helps Time Machine decide when to back up, and starts automatic backups.",
            maker: .apple,
            busyWhen: "Briefly, about every half hour, when it checks whether a backup is due.",
            quit: .relaunches, whatToDo: nil,
            findingNote: "Time Machine is backing up.",
            names: ["backupd-helper"],
            groundedIn: "x-man-page://8/backupd-helper; file:///System/Library/LaunchDaemons/com.apple.backupd-helper.plist; x-man-page://5/launchd.plist"),
    ]
}
