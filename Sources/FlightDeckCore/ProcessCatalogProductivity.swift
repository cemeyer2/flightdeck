import Foundation

enum ProcessCatalogProductivity {
    static let part: [ProcessExplanation] = [

        // MARK: - Communication

        ProcessExplanation(
            id: "apps-slack", title: "Slack",
            summary: "Slack, a messaging app for teams. It runs web content in separate helper processes, so a busy channel or call shows up there rather than in the main app.",
            maker: .vendor("Slack Technologies"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Slack or one of its helper processes is busy.",
            pathPrefixes: ["/Applications/Slack.app/"],
            bundleIDs: ["com.tinyspeck.slackmacgap"], teamIDs: ["BQR82RBBHL"],
            groundedIn: "https://slack.com/; file:///Applications/Slack.app"),

        ProcessExplanation(
            id: "apps-teams", title: "Microsoft Teams",
            summary: "Microsoft Teams, Microsoft's app for chat, meetings, calls and collaboration.",
            maker: .vendor("Microsoft"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Microsoft Teams is busy.",
            pathPrefixes: ["/Applications/Microsoft Teams.app/", "/Applications/Microsoft Teams classic.app/"],
            bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"], teamIDs: ["UBF8T346G9"],
            groundedIn: "https://www.microsoft.com/en-us/microsoft-teams/; file:///Applications/Microsoft%20Teams.app"),

        ProcessExplanation(
            id: "apps-discord", title: "Discord",
            summary: "Discord, a messaging and voice chat app popular for gaming communities and many other groups. It uses separate helper processes for web content.",
            maker: .vendor("Discord Inc."),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Discord or one of its helper processes is busy.",
            pathPrefixes: ["/Applications/Discord.app/"],
            bundleIDs: ["com.hnc.Discord"], teamIDs: ["53Q6R32WPB"],
            groundedIn: "https://discord.com/; file:///Applications/Discord.app"),

        ProcessExplanation(
            id: "apps-signal", title: "Signal",
            summary: "Signal, a privacy-focused messaging and calling app that uses end-to-end encryption for all messages and calls.",
            maker: .vendor("Signal Messenger"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Signal is busy.",
            pathPrefixes: ["/Applications/Signal.app/"],
            bundleIDs: ["org.whispersystems.signal-desktop"],
            groundedIn: "https://signal.org/; file:///Applications/Signal.app"),

        ProcessExplanation(
            id: "apps-telegram", title: "Telegram",
            summary: "Telegram, a cloud-based messaging app known for its speed and large group support.",
            maker: .vendor("Telegram"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Telegram is busy.",
            pathPrefixes: ["/Applications/Telegram.app/"],
            bundleIDs: ["ru.keepcoder.Telegram"], teamIDs: ["6N38VWS5BX"],
            groundedIn: "https://telegram.org/; file:///Applications/Telegram.app"),

        ProcessExplanation(
            id: "apps-whatsapp", title: "WhatsApp",
            summary: "WhatsApp, Meta's messaging and calling app.",
            maker: .vendor("Meta"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "WhatsApp is busy.",
            pathPrefixes: ["/Applications/WhatsApp.app/"],
            bundleIDs: ["net.whatsapp.WhatsApp"], teamIDs: ["57T9237FN3"],
            groundedIn: "https://www.whatsapp.com/; file:///Applications/WhatsApp.app"),

        ProcessExplanation(
            id: "apps-skype", title: "Skype",
            summary: "Skype, Microsoft's video and voice calling app.",
            maker: .vendor("Microsoft"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Skype is busy.",
            pathPrefixes: ["/Applications/Skype.app/"],
            bundleIDs: ["com.skype.skype"], teamIDs: ["UBF8T346G9"],
            groundedIn: "https://www.skype.com/; file:///Applications/Skype.app"),

        ProcessExplanation(
            id: "apps-viber", title: "Viber",
            summary: "Viber, a messaging and calling app that works across platforms.",
            maker: .vendor("Viber Media"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Viber is busy.",
            pathPrefixes: ["/Applications/Viber.app/"],
            bundleIDs: ["com.viber.Viber"],
            groundedIn: "https://www.viber.com/; file:///Applications/Viber.app"),

        // MARK: - Microsoft Office

        ProcessExplanation(
            id: "apps-word", title: "Microsoft Word",
            summary: "Microsoft Word, the word processor in Microsoft 365.",
            maker: .vendor("Microsoft"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Microsoft Word is busy.",
            pathPrefixes: ["/Applications/Microsoft Word.app/"],
            bundleIDs: ["com.microsoft.Word"], teamIDs: ["UBF8T346G9"],
            groundedIn: "https://www.microsoft.com/en-us/microsoft-365/word; file:///Applications/Microsoft%20Word.app"),

        ProcessExplanation(
            id: "apps-excel", title: "Microsoft Excel",
            summary: "Microsoft Excel, the spreadsheet app in Microsoft 365.",
            maker: .vendor("Microsoft"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Microsoft Excel is busy.",
            pathPrefixes: ["/Applications/Microsoft Excel.app/"],
            bundleIDs: ["com.microsoft.Excel"], teamIDs: ["UBF8T346G9"],
            groundedIn: "https://www.microsoft.com/en-us/microsoft-365/excel; file:///Applications/Microsoft%20Excel.app"),

        ProcessExplanation(
            id: "apps-powerpoint", title: "Microsoft PowerPoint",
            summary: "Microsoft PowerPoint, the presentation app in Microsoft 365.",
            maker: .vendor("Microsoft"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Microsoft PowerPoint is busy.",
            pathPrefixes: ["/Applications/Microsoft PowerPoint.app/"],
            bundleIDs: ["com.microsoft.Powerpoint"], teamIDs: ["UBF8T346G9"],
            groundedIn: "https://www.microsoft.com/en-us/microsoft-365/powerpoint; file:///Applications/Microsoft%20PowerPoint.app"),

        ProcessExplanation(
            id: "apps-outlook", title: "Microsoft Outlook",
            summary: "Microsoft Outlook, the email and calendar app in Microsoft 365.",
            maker: .vendor("Microsoft"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Microsoft Outlook is busy.",
            pathPrefixes: ["/Applications/Microsoft Outlook.app/"],
            bundleIDs: ["com.microsoft.Outlook"], teamIDs: ["UBF8T346G9"],
            groundedIn: "https://www.microsoft.com/en-us/microsoft-365/outlook; file:///Applications/Microsoft%20Outlook.app"),

        ProcessExplanation(
            id: "apps-onenote", title: "Microsoft OneNote",
            summary: "Microsoft OneNote, the note-taking app in Microsoft 365.",
            maker: .vendor("Microsoft"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Microsoft OneNote is busy.",
            pathPrefixes: ["/Applications/Microsoft OneNote.app/"],
            bundleIDs: ["com.microsoft.onenote.mac"], teamIDs: ["UBF8T346G9"],
            groundedIn: "https://www.microsoft.com/en-us/microsoft-365/onenote; file:///Applications/Microsoft%20OneNote.app"),

        ProcessExplanation(
            id: "apps-onedrive", title: "Microsoft OneDrive",
            summary: "Microsoft OneDrive, which syncs your OneDrive files to this Mac and keeps them up to date.",
            maker: .vendor("Microsoft"),
            busyWhen: "While files are uploading or downloading, and in periodic background sync checks.",
            quit: .avoid, whatToDo: nil,
            findingNote: "OneDrive is syncing files.",
            pathPrefixes: ["/Applications/OneDrive.app/"],
            bundleIDs: ["com.microsoft.OneDrive"], teamIDs: ["UBF8T346G9"],
            groundedIn: "https://www.microsoft.com/en-us/microsoft-365/onedrive; file:///Applications/OneDrive.app"),

        // MARK: - Cloud Storage

        ProcessExplanation(
            id: "apps-dropbox", title: "Dropbox",
            summary: "Dropbox, which syncs your Dropbox files to this Mac and keeps them up to date.",
            maker: .vendor("Dropbox, Inc."),
            busyWhen: "While files are uploading or downloading, and in periodic background sync checks.",
            quit: .avoid, whatToDo: nil,
            findingNote: "Dropbox is syncing files.",
            pathPrefixes: ["/Applications/Dropbox.app/"],
            bundleIDs: ["com.getdropbox.dropbox"], teamIDs: ["G7HH3F8CAK"],
            groundedIn: "https://www.dropbox.com/; file:///Applications/Dropbox.app"),

        ProcessExplanation(
            id: "apps-box", title: "Box",
            summary: "Box for Mac, which syncs your Box files to this Mac and keeps them up to date.",
            maker: .vendor("Box, Inc."),
            busyWhen: "While files are uploading or downloading, and in periodic background sync checks.",
            quit: .avoid, whatToDo: nil,
            findingNote: "Box is syncing files.",
            pathPrefixes: ["/Applications/Box.app/"],
            bundleIDs: ["com.box.desktop"], teamIDs: ["M683GB7CPW"],
            groundedIn: "https://www.box.com/; file:///Applications/Box.app"),

        ProcessExplanation(
            id: "apps-googledrive", title: "Google Drive",
            summary: "Google Drive for desktop, which syncs your Google Drive files to this Mac and keeps them up to date.",
            maker: .vendor("Google"),
            busyWhen: "While files are uploading or downloading, and in periodic background sync checks.",
            quit: .avoid, whatToDo: nil,
            findingNote: "Google Drive is syncing files.",
            pathPrefixes: ["/Applications/Google Drive.app/"],
            bundleIDs: ["com.google.GoogleDrive"], teamIDs: ["EQHXZ8M8AV"],
            groundedIn: "https://drive.google.com/; file:///Applications/Google%20Drive.app"),

        // MARK: - Productivity and Notes

        ProcessExplanation(
            id: "apps-notion", title: "Notion",
            summary: "Notion, an all-in-one workspace for notes, docs, databases and project tracking.",
            maker: .vendor("Notion Labs"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Notion is busy.",
            pathPrefixes: ["/Applications/Notion.app/"],
            bundleIDs: ["notion.id"], teamIDs: ["LHVFM7W7CU"],
            groundedIn: "https://www.notion.com/; file:///Applications/Notion.app"),

        ProcessExplanation(
            id: "apps-obsidian", title: "Obsidian",
            summary: "Obsidian, a Markdown note-taking app that stores your notes as local files and links them together.",
            maker: .vendor("Dynalist Inc."),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Obsidian is busy.",
            pathPrefixes: ["/Applications/Obsidian.app/"],
            bundleIDs: ["md.obsidian"], teamIDs: ["4P66CQ8T37"],
            groundedIn: "https://obsidian.md/; file:///Applications/Obsidian.app"),

        ProcessExplanation(
            id: "apps-craft", title: "Craft",
            summary: "Craft, a document and note editor for Mac and iOS.",
            maker: .vendor("Luki Lab"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Craft is busy.",
            pathPrefixes: ["/Applications/Craft.app/"],
            bundleIDs: ["si.craft.craftdocs"], teamIDs: ["9PNBK3B9TK"],
            groundedIn: "https://www.craft.do/; file:///Applications/Craft.app"),

        ProcessExplanation(
            id: "apps-bear", title: "Bear",
            summary: "Bear, a focused Markdown note-taking app for Mac and iOS.",
            maker: .vendor("Shiny Frog"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Bear is busy.",
            pathPrefixes: ["/Applications/Bear.app/"],
            bundleIDs: ["net.shinyfrog.bear"], teamIDs: ["V4BK96S8UK"],
            groundedIn: "https://bear.app/; file:///Applications/Bear.app"),

        ProcessExplanation(
            id: "apps-dayone", title: "Day One",
            summary: "Day One, a journaling app for Mac and iOS.",
            maker: .vendor("Bloom Built"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Day One is busy.",
            pathPrefixes: ["/Applications/Day One.app/"],
            bundleIDs: ["com.bloombuilt.dayone-mac"], teamIDs: ["4RB9S2LZ7K"],
            groundedIn: "https://dayoneapp.com/; file:///Applications/Day%20One.app"),

        ProcessExplanation(
            id: "apps-ulysses", title: "Ulysses",
            summary: "Ulysses, a writing app for long-form text, fiction and blog posts.",
            maker: .vendor("The Soulmen"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Ulysses is busy.",
            pathPrefixes: ["/Applications/Ulysses.app/"],
            bundleIDs: ["com.soulmen.ulysses-osx"], teamIDs: ["92C2SD82GG"],
            groundedIn: "https://ulysses.app/; file:///Applications/Ulysses.app"),

        ProcessExplanation(
            id: "apps-iawriter", title: "iA Writer",
            summary: "iA Writer, a focused Markdown writing app.",
            maker: .vendor("iA Labs"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "iA Writer is busy.",
            pathPrefixes: ["/Applications/iA Writer.app/"],
            bundleIDs: ["pro.writer.mac"],
            groundedIn: "https://ia.net/writer; file:///Applications/iA%20Writer.app"),

        ProcessExplanation(
            id: "apps-reeder", title: "Reeder",
            summary: "Reeder, an RSS and read-later client for Mac.",
            maker: .vendor("Silvio Rizzi"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Reeder is busy.",
            pathPrefixes: ["/Applications/Reeder.app/", "/Applications/Reeder 5.app/"],
            bundleIDs: ["com.reederapp.5.macOS"], teamIDs: ["G67927HV67"],
            groundedIn: "https://reeder.app/; file:///Applications/Reeder.app"),

        // MARK: - Task Management

        ProcessExplanation(
            id: "apps-things", title: "Things 3",
            summary: "Things 3, a task manager and to-do list app by Cultured Code.",
            maker: .vendor("Cultured Code"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Things is busy.",
            pathPrefixes: ["/Applications/Things3.app/", "/Applications/Things 3.app/"],
            bundleIDs: ["com.culturedcode.ThingsMac"], teamIDs: ["JLMPQHK86H"],
            groundedIn: "https://culturedcode.com/things/; file:///Applications/Things3.app"),

        ProcessExplanation(
            id: "apps-omnifocus", title: "OmniFocus",
            summary: "OmniFocus, a powerful task manager by The Omni Group.",
            maker: .vendor("The Omni Group"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "OmniFocus is busy.",
            pathPrefixes: ["/Applications/OmniFocus.app/"],
            bundleIDs: ["com.omnigroup.OmniFocus4", "com.omnigroup.OmniFocus3"],
            teamIDs: ["34YW5XSRB7"],
            groundedIn: "https://www.omnigroup.com/omnifocus/; file:///Applications/OmniFocus.app"),

        ProcessExplanation(
            id: "apps-fantastical", title: "Fantastical",
            summary: "Fantastical, a calendar and task manager with natural language input.",
            maker: .vendor("Flexibits"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Fantastical is busy.",
            pathPrefixes: ["/Applications/Fantastical.app/"],
            bundleIDs: ["com.flexibits.fantastical2.mac"], teamIDs: ["H8M3X2RRQL"],
            groundedIn: "https://flexibits.com/fantastical; file:///Applications/Fantastical.app"),

        ProcessExplanation(
            id: "apps-busycal", title: "BusyCal",
            summary: "BusyCal, a calendar app with task management and weather integration.",
            maker: .vendor("BusyMac"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "BusyCal is busy.",
            pathPrefixes: ["/Applications/BusyCal.app/"],
            bundleIDs: ["com.busymac.busycal3"], teamIDs: ["RJB3WZEBU3"],
            groundedIn: "https://www.busymac.com/busycal/; file:///Applications/BusyCal.app"),

        ProcessExplanation(
            id: "apps-linear", title: "Linear",
            summary: "Linear, a project and issue tracking app used by software teams.",
            maker: .vendor("Linear Orbit"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Linear is busy.",
            pathPrefixes: ["/Applications/Linear.app/"],
            bundleIDs: ["com.linear"], teamIDs: ["7UFZXP6PHN"],
            groundedIn: "https://linear.app/; file:///Applications/Linear.app"),

        // MARK: - Other

        ProcessExplanation(
            id: "apps-spotify", title: "Spotify",
            summary: "Spotify, a music and podcast streaming app. Its audio plays through the Mac's normal audio system.",
            maker: .vendor("Spotify AB"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Spotify is busy.",
            pathPrefixes: ["/Applications/Spotify.app/"],
            bundleIDs: ["com.spotify.client"], teamIDs: ["2FNC3A47ZF"],
            groundedIn: "https://www.spotify.com/; file:///Applications/Spotify.app"),

        ProcessExplanation(
            id: "apps-backblaze", title: "Backblaze backup",
            summary: "Backblaze, which continuously backs up your files to the cloud. It runs as a background service.",
            maker: .vendor("Backblaze"),
            busyWhen: "While files are being uploaded to the cloud, particularly after a large number of changes.",
            quit: .avoid, whatToDo: nil,
            findingNote: "Backblaze is backing up your files.",
            pathPrefixes: ["/Library/Backblaze.bzpkg/", "/Applications/Backblaze.app/"],
            bundleIDs: ["com.backblaze.backup.helper"],
            groundedIn: "https://www.backblaze.com/; file:///Applications/Backblaze.app"),

        ProcessExplanation(
            id: "apps-dropzone", title: "Dropzone",
            summary: "Dropzone, a productivity utility that lets you drag files to quickly copy, move or upload them.",
            maker: .vendor("Aptonic"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Dropzone is busy.",
            pathPrefixes: ["/Applications/Dropzone 4.app/"],
            bundleIDs: ["com.aptonic.Dropzone4"],
            groundedIn: "https://aptonic.com/; file:///Applications/Dropzone%204.app"),
    ]
}
