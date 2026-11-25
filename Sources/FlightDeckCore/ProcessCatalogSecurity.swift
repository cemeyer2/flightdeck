// PENDING USER REVIEW: batch 5/12, macOS security, privacy, code signing
import Foundation

enum ProcessCatalogSecurity {
    static let part: [ProcessExplanation] = [
        ProcessExplanation(
            id: "security-xprotect", title: "XProtect malware protection",
            summary: "macOS's built-in protection against known malware. It detects and blocks known malware, and removes infections it finds.",
            maker: .apple,
            busyWhen: "When an app is first opened or has changed, and after XProtect's signatures are updated.",
            quit: .relaunches, whatToDo: nil,
            findingNote: "macOS is scanning apps for malware or checking signatures.",
            names: ["XProtect", "XprotectService", "xprotectd"],
            groundedIn: "https://support.apple.com/guide/security/protecting-against-malware-sec469d47bd8/web; file:///System/Library/LaunchDaemons/com.apple.security.xprotectd.plist; file:///System/Library/PrivateFrameworks/XprotectFramework.framework/Versions/A/XPCServices/XprotectService.xpc; file:///Library/Apple/System/Library/CoreServices/XProtect.app; x-man-page://8/launchd"),
        ProcessExplanation(
            id: "security-syspolicyd", title: "System policy daemon",
            summary: "Applies macOS's policy on what may be installed, loaded or run, and answers other parts of macOS that ask for its verdict.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "macOS is scanning apps for malware or checking signatures.",
            names: ["syspolicyd"],
            groundedIn: "x-man-page://8/syspolicyd; file:///System/Library/LaunchDaemons/com.apple.security.syspolicy.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "security-trustd", title: "Certificate trust checks",
            summary: "Checks whether certificates can be trusted, for every process on the Mac.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "macOS is scanning apps for malware or checking signatures.",
            names: ["trustd"],
            groundedIn: "x-man-page://8/trustd; file:///System/Library/LaunchDaemons/com.apple.trustd.plist; file:///System/Library/LaunchAgents/com.apple.trustd.agent.plist; x-man-page://5/launchd.plist"),
    ]
}
