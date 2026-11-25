// PENDING USER REVIEW: batch 3/12, Photos, media, audio, camera
import Foundation

enum ProcessCatalogMedia {
    static let part: [ProcessExplanation] = [
        ProcessExplanation(
            id: "photos-photoanalysisd", title: "Photos library analysis",
            summary: "Analyses your photo library in the background for Memories, People, and searching by scene or object.",
            maker: .apple,
            busyWhen: "In background tasks every few hours, only while the Mac is on power.",
            quit: .relaunches, whatToDo: nil,
            findingNote: "Photos is analysing your library (faces, scenes). It runs mostly when the Mac is idle or charging.",
            names: ["photoanalysisd"],
            groundedIn: "x-man-page://8/photoanalysisd; file:///System/Library/LaunchAgents/com.apple.photoanalysisd.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "photos-photolibraryd", title: "Photos library agent",
            summary: "Handles every request to read or change your photo library, from Photos and other apps.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "Your photo library is being read or updated.",
            names: ["photolibraryd"],
            groundedIn: "x-man-page://8/photolibraryd; file:///System/Library/LaunchAgents/com.apple.photolibraryd.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "media-mediaanalysisd", title: "Media analysis",
            summary: "Analyses photos and videos on the Mac for system features. It's part of macOS's MediaAnalysis framework.",
            maker: .apple,
            busyWhen: "In a background task about once an hour while you aren't using the Mac.",
            quit: .relaunches, whatToDo: nil,
            findingNote: "macOS is analysing photos or videos in the background. It runs mostly while the Mac is idle.",
            names: ["mediaanalysisd"],
            groundedIn: "file:///System/Library/LaunchAgents/com.apple.mediaanalysisd.plist; file:///System/Library/PrivateFrameworks/MediaAnalysis.framework; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "audio-coreaudiod", title: "Core Audio daemon",
            summary: "Runs Core Audio, the part of macOS that apps use to play and record sound through the Mac's audio hardware.",
            maker: .apple,
            busyWhen: "While apps play or record sound.",
            quit: .avoid, whatToDo: nil,
            findingNote: "The audio system is busy.",
            names: ["coreaudiod"], paths: ["/usr/sbin/coreaudiod"],
            groundedIn: "x-man-page://8/coreaudiod; https://developer.apple.com/documentation/coreaudio; file:///System/Library/LaunchDaemons/com.apple.audio.coreaudiod.plist"),
    ]
}
