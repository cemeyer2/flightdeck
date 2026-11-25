// PENDING USER REVIEW: batch 9/12, Browsers and web content
import Foundation

enum ProcessCatalogBrowsers {
    static let part: [ProcessExplanation] = [
        ProcessExplanation(
            id: "browser-chrome", title: "Google Chrome and its helpers",
            summary: "Google's web browser. The main process runs the interface, and web content runs in separate renderer helpers, usually one per tab, so a bug in one page can't take down the rest.",
            maker: .vendor("Google"),
            busyWhen: nil,
            quit: .avoid, whatToDo: nil,
            findingNote: "Chrome runs each tab and extension as a separate helper process.",
            pathPrefixes: ["/Applications/Google Chrome.app/"],
            bundleIDs: ["com.google.Chrome"], teamIDs: ["EQHXZ8M8AV"],
            groundedIn: "https://www.chromium.org/developers/design-documents/multi-process-architecture/; file:///Applications/Google%20Chrome.app"),
        ProcessExplanation(
            id: "browser-webkit", title: "WebKit web content",
            summary: "Part of WebKit, the web engine used by Safari, Mail, the App Store and many other apps. Web content runs in these separate processes, apart from the app's own window.",
            maker: .apple,
            busyWhen: "While a page in Safari or a web view in another app is busy.",
            quit: .relaunches, whatToDo: nil,
            findingNote: "A Safari (or WebKit) tab or web view is busy.",
            namePrefixes: ["com.apple.WebKit."],
            groundedIn: "https://webkit.org/; https://trac.webkit.org/wiki/WebKit2; file:///System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices; x-man-page://8/launchd"),
        ProcessExplanation(
            id: "browser-safari", title: "Safari",
            summary: "Apple's web browser. Like other apps that use WebKit, it shows each page's content through separate WebKit processes.",
            maker: .apple,
            busyWhen: nil,
            quit: .avoid, whatToDo: nil,
            findingNote: "Safari itself is busy. Busy pages usually show up as separate WebKit processes.",
            names: ["Safari"], pathPrefixes: ["/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/", "/System/Cryptexes/App/System/Applications/Safari.app/"],
            groundedIn: "https://support.apple.com/guide/safari/welcome/mac; https://webkit.org/; https://trac.webkit.org/wiki/WebKit2; file:///System/Cryptexes/App/System/Applications/Safari.app"),
        ProcessExplanation(
            id: "browser-arc", title: "Arc browser",
            summary: "Arc, a web browser made by The Browser Company of New York.",
            maker: .vendor("The Browser Company"),
            busyWhen: nil,
            quit: .avoid, whatToDo: nil,
            findingNote: "Arc or one of its pages is busy.",
            pathPrefixes: ["/Applications/Arc.app/"], bundleIDs: ["company.thebrowser.Browser"], teamIDs: ["S6N382Y83G"],
            groundedIn: "https://arc.net/; file:///Applications/Arc.app"),
        ProcessExplanation(
            id: "browser-firefox", title: "Firefox and its helpers",
            summary: "Mozilla's Firefox web browser and the helper processes that ship inside it.",
            maker: .vendor("Mozilla"),
            busyWhen: nil,
            quit: .avoid, whatToDo: nil,
            findingNote: "Firefox or one of its pages is busy.",
            pathPrefixes: ["/Applications/Firefox.app/"], bundleIDs: ["org.mozilla.firefox"], teamIDs: ["43AQ936H96"],
            groundedIn: "https://www.firefox.com/en-US/; file:///Applications/Firefox.app"),
    ]
}
