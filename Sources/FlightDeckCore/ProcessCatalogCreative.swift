import Foundation

enum ProcessCatalogCreative {
    static let part: [ProcessExplanation] = [

        // MARK: - Apple pro apps

        ProcessExplanation(
            id: "creative-logicpro", title: "Logic Pro",
            summary: "Apple's professional digital audio workstation for composing, recording, editing and mixing music.",
            maker: .apple,
            busyWhen: "While recording, playing back, or processing audio with plug-ins.",
            quit: .app, whatToDo: nil,
            findingNote: "Logic Pro is busy.",
            pathPrefixes: ["/Applications/Logic Pro.app/"],
            bundleIDs: ["com.apple.logic10"],
            groundedIn: "https://www.apple.com/logic-pro/; file:///Applications/Logic%20Pro.app"),

        ProcessExplanation(
            id: "creative-finalcutpro", title: "Final Cut Pro",
            summary: "Apple's professional video editing application for cutting, colour-grading and publishing video.",
            maker: .apple,
            busyWhen: "While rendering, exporting, or performing background analysis of media.",
            quit: .app, whatToDo: nil,
            findingNote: "Final Cut Pro is busy.",
            pathPrefixes: ["/Applications/Final Cut Pro.app/"],
            bundleIDs: ["com.apple.FinalCut"],
            groundedIn: "https://www.apple.com/final-cut-pro/; file:///Applications/Final%20Cut%20Pro.app"),

        ProcessExplanation(
            id: "creative-motion", title: "Motion",
            summary: "Apple's motion graphics tool for creating titles, transitions and effects for use in Final Cut Pro.",
            maker: .apple,
            busyWhen: "While rendering or previewing complex animations.",
            quit: .app, whatToDo: nil,
            findingNote: "Motion is busy.",
            pathPrefixes: ["/Applications/Motion.app/"],
            bundleIDs: ["com.apple.motionapp"],
            groundedIn: "https://www.apple.com/final-cut-pro/motion/; file:///Applications/Motion.app"),

        ProcessExplanation(
            id: "creative-compressor", title: "Compressor",
            summary: "Apple's video and audio encoding tool, used to export projects from Final Cut Pro and Logic Pro in a wide range of formats.",
            maker: .apple,
            busyWhen: "While encoding or transcoding video or audio files.",
            quit: .app, whatToDo: nil,
            findingNote: "Compressor is encoding or transcoding media.",
            pathPrefixes: ["/Applications/Compressor.app/"],
            bundleIDs: ["com.apple.Compressor"],
            groundedIn: "https://www.apple.com/final-cut-pro/compressor/; file:///Applications/Compressor.app"),

        ProcessExplanation(
            id: "creative-mainstage", title: "MainStage",
            summary: "Apple's live performance app for musicians, providing a full instrument and effects rig powered by the Mac.",
            maker: .apple,
            busyWhen: "During live performance or while loading a large concert with many instruments.",
            quit: .app, whatToDo: nil,
            findingNote: "MainStage is busy.",
            pathPrefixes: ["/Applications/MainStage.app/"],
            bundleIDs: ["com.apple.MainStage"],
            groundedIn: "https://www.apple.com/mainstage/; file:///Applications/MainStage.app"),

        ProcessExplanation(
            id: "creative-garageband", title: "GarageBand",
            summary: "Apple's music creation app for recording, arranging and mixing songs with instruments, loops and effects.",
            maker: .apple,
            busyWhen: "While recording or playing back a project with many tracks or plug-ins.",
            quit: .app, whatToDo: nil,
            findingNote: "GarageBand is busy.",
            pathPrefixes: ["/Applications/GarageBand.app/"],
            bundleIDs: ["com.apple.garageband10"],
            groundedIn: "https://www.apple.com/garageband/; file:///Applications/GarageBand.app"),

        // MARK: - Audio production

        ProcessExplanation(
            id: "creative-ableton-live", title: "Ableton Live",
            summary: "Ableton Live, a digital audio workstation designed for music creation, live performance and DJing.",
            maker: .vendor("Ableton AG"),
            busyWhen: "While recording, playing back, or processing audio with complex effect chains.",
            quit: .app, whatToDo: nil,
            findingNote: "Ableton Live is busy.",
            namePrefixes: ["Ableton Live"],
            bundleIDs: ["com.ableton.live"], teamIDs: ["9CXZM2KAFU"],
            groundedIn: "https://www.ableton.com/en/live/; file:///Applications"),

        ProcessExplanation(
            id: "creative-komplete-kontrol", title: "Komplete Kontrol",
            summary: "Native Instruments' Komplete Kontrol, a plug-in host and browser for NI instruments and effects.",
            maker: .vendor("Native Instruments"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Komplete Kontrol is busy.",
            pathPrefixes: ["/Applications/Native Instruments/Komplete Kontrol.app/"],
            bundleIDs: ["de.native-instruments.kontrol"], teamIDs: ["5ZE6U387CU"],
            groundedIn: "https://www.native-instruments.com/en/products/komplete/keyboards/komplete-kontrol/; file:///Applications/Native%20Instruments"),

        ProcessExplanation(
            id: "creative-splice", title: "Splice",
            summary: "Splice, a platform for downloading sample packs, loops and plug-ins for music production.",
            maker: .vendor("Splice"),
            busyWhen: "While downloading or syncing samples and projects.",
            quit: .app, whatToDo: nil,
            findingNote: "Splice is busy.",
            pathPrefixes: ["/Applications/Splice.app/"],
            bundleIDs: ["com.splice.Splice"],
            groundedIn: "https://splice.com/; file:///Applications/Splice.app"),

        // MARK: - Video

        ProcessExplanation(
            id: "creative-davinci-resolve", title: "DaVinci Resolve",
            summary: "Blackmagic Design's DaVinci Resolve, a professional video editing, colour grading, visual effects and audio post-production application.",
            maker: .vendor("Blackmagic Design"),
            busyWhen: "While rendering, grading, or exporting video projects.",
            quit: .app, whatToDo: nil,
            findingNote: "DaVinci Resolve is busy.",
            pathPrefixes: ["/Applications/DaVinci Resolve.app/"],
            bundleIDs: ["com.blackmagic-design.davinci-resolve"], teamIDs: ["N7G93QBMMR"],
            groundedIn: "https://www.blackmagicdesign.com/products/davinciresolve; file:///Applications/DaVinci%20Resolve.app"),

        ProcessExplanation(
            id: "creative-handbrake", title: "HandBrake",
            summary: "HandBrake, an open-source video transcoder for converting video files between formats.",
            maker: .vendor("HandBrake Team"),
            busyWhen: "While encoding video, which can fully load multiple CPU cores.",
            quit: .app, whatToDo: nil,
            findingNote: "HandBrake is encoding video.",
            pathPrefixes: ["/Applications/HandBrake.app/"],
            bundleIDs: ["fr.handbrake.HandBrake"], teamIDs: ["5F9FVAM35V"],
            groundedIn: "https://handbrake.fr/; file:///Applications/HandBrake.app"),

        ProcessExplanation(
            id: "creative-obs", title: "OBS Studio",
            summary: "OBS Studio, free and open-source software for video recording and live streaming.",
            maker: .vendor("OBS Project"),
            busyWhen: "While recording or streaming video — it encodes every frame in real time.",
            quit: .avoid, whatToDo: "Stop the recording or stream before quitting.",
            findingNote: "OBS Studio is recording or streaming video.",
            pathPrefixes: ["/Applications/OBS.app/"],
            bundleIDs: ["com.obsproject.obs-studio"], teamIDs: ["2MMRE5MTK8"],
            groundedIn: "https://obsproject.com/; file:///Applications/OBS.app"),

        ProcessExplanation(
            id: "creative-vlc", title: "VLC",
            summary: "VLC, a free and open-source media player that plays almost any video or audio format.",
            maker: .vendor("VideoLAN"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "VLC is busy.",
            pathPrefixes: ["/Applications/VLC.app/"],
            bundleIDs: ["org.videolan.vlc"], teamIDs: ["75GAHG3SZQ"],
            groundedIn: "https://www.videolan.org/vlc/; file:///Applications/VLC.app"),

        ProcessExplanation(
            id: "creative-plex", title: "Plex",
            summary: "Plex, a media player client that streams movies, TV shows, music and photos from a Plex Media Server.",
            maker: .vendor("Plex"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Plex is busy.",
            pathPrefixes: ["/Applications/Plex.app/"],
            bundleIDs: ["tv.plex.desktop"], teamIDs: ["86YU5CSPRL"],
            groundedIn: "https://www.plex.tv/; file:///Applications/Plex.app"),

        ProcessExplanation(
            id: "creative-infuse", title: "Infuse",
            summary: "Infuse by Firecore, a video player with broad format support and streaming from local and network sources.",
            maker: .vendor("Firecore"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Infuse is busy.",
            pathPrefixes: ["/Applications/Infuse 7.app/", "/Applications/Infuse.app/"],
            bundleIDs: ["com.firecore.Infuse"], teamIDs: ["46SF5G3LUQ"],
            groundedIn: "https://firecore.com/infuse; file:///Applications/Infuse%207.app"),

        ProcessExplanation(
            id: "creative-iina", title: "IINA",
            summary: "IINA, a modern open-source video player for macOS built on mpv.",
            maker: .vendor("IINA"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "IINA is busy.",
            pathPrefixes: ["/Applications/IINA.app/"],
            bundleIDs: ["com.colliderli.iina"], teamIDs: ["6449DSDAV3"],
            groundedIn: "https://iina.io/; file:///Applications/IINA.app"),

        // MARK: - Design

        ProcessExplanation(
            id: "creative-figma", title: "Figma",
            summary: "Figma, a collaborative interface design tool used for UI/UX design, prototyping and design systems.",
            maker: .vendor("Figma"),
            busyWhen: "While loading large files or running complex auto-layout and plugins.",
            quit: .app, whatToDo: nil,
            findingNote: "Figma is busy.",
            pathPrefixes: ["/Applications/Figma.app/"],
            bundleIDs: ["com.figma.Desktop"], teamIDs: ["T8TE6B856V"],
            groundedIn: "https://www.figma.com/; file:///Applications/Figma.app"),

        ProcessExplanation(
            id: "creative-sketch", title: "Sketch",
            summary: "Sketch by Bohemian Coding, a vector design tool for creating user interfaces, icons and illustrations on the Mac.",
            maker: .vendor("Bohemian Coding"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Sketch is busy.",
            pathPrefixes: ["/Applications/Sketch.app/"],
            bundleIDs: ["com.bohemiancoding.sketch3"], teamIDs: ["WUGMZCOM1J"],
            groundedIn: "https://www.sketch.com/; file:///Applications/Sketch.app"),

        ProcessExplanation(
            id: "creative-affinity-designer", title: "Affinity Designer",
            summary: "Affinity Designer by Serif, a professional vector and raster graphics editor.",
            maker: .vendor("Serif Labs"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Affinity Designer is busy.",
            pathPrefixes: ["/Applications/Affinity Designer 2.app/", "/Applications/Affinity Designer.app/"],
            bundleIDs: ["com.seriflabs.affinitydesigner2"], teamIDs: ["7FXKV92FUL"],
            groundedIn: "https://affinity.serif.com/en-us/designer/; file:///Applications/Affinity%20Designer%202.app"),

        ProcessExplanation(
            id: "creative-affinity-photo", title: "Affinity Photo",
            summary: "Affinity Photo by Serif, a professional photo editing and retouching application.",
            maker: .vendor("Serif Labs"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Affinity Photo is busy.",
            pathPrefixes: ["/Applications/Affinity Photo 2.app/", "/Applications/Affinity Photo.app/"],
            bundleIDs: ["com.seriflabs.affinityphoto2"], teamIDs: ["7FXKV92FUL"],
            groundedIn: "https://affinity.serif.com/en-us/photo/; file:///Applications/Affinity%20Photo%202.app"),

        ProcessExplanation(
            id: "creative-affinity-publisher", title: "Affinity Publisher",
            summary: "Affinity Publisher by Serif, a professional desktop publishing application for layouts, books and marketing materials.",
            maker: .vendor("Serif Labs"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Affinity Publisher is busy.",
            pathPrefixes: ["/Applications/Affinity Publisher 2.app/", "/Applications/Affinity Publisher.app/"],
            bundleIDs: ["com.seriflabs.affinitypublisher2"], teamIDs: ["7FXKV92FUL"],
            groundedIn: "https://affinity.serif.com/en-us/publisher/; file:///Applications/Affinity%20Publisher%202.app"),

        ProcessExplanation(
            id: "creative-pixelmator", title: "Pixelmator Pro",
            summary: "Pixelmator Pro, a full-featured image editor for the Mac with machine-learning-powered tools.",
            maker: .vendor("Pixelmator Team"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Pixelmator Pro is busy.",
            pathPrefixes: ["/Applications/Pixelmator Pro.app/"],
            bundleIDs: ["com.pixelmatorteam.pixelmator.x"], teamIDs: ["FFSABU279C"],
            groundedIn: "https://www.pixelmator.com/pro/; file:///Applications/Pixelmator%20Pro.app"),

        ProcessExplanation(
            id: "creative-canva", title: "Canva",
            summary: "Canva, an online design platform with a Mac app for creating graphics, presentations, documents and social media content.",
            maker: .vendor("Canva"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Canva is busy.",
            pathPrefixes: ["/Applications/Canva.app/"],
            bundleIDs: ["com.canva.CanvaDesktop"],
            groundedIn: "https://www.canva.com/; file:///Applications/Canva.app"),

        ProcessExplanation(
            id: "creative-miro", title: "Miro",
            summary: "Miro, a collaborative online whiteboard platform for brainstorming, diagramming and remote workshops.",
            maker: .vendor("RealtimeBoard"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Miro is busy.",
            pathPrefixes: ["/Applications/Miro.app/"],
            bundleIDs: ["com.electron.realtimeboard"],
            groundedIn: "https://miro.com/; file:///Applications/Miro.app"),

        // MARK: - Adobe Creative Cloud

        ProcessExplanation(
            id: "creative-adobe-cc", title: "Adobe Creative Cloud",
            summary: "Adobe Creative Cloud, the background helper that manages your Adobe app licences, updates and cloud services. All Adobe apps depend on it.",
            maker: .vendor("Adobe"),
            busyWhen: "When an Adobe app is launching, being updated, or when Creative Cloud syncs your assets.",
            quit: .avoid, whatToDo: "Quitting it may cause Adobe apps to lose their licence. Restart it from /Applications/Utilities/Adobe Creative Cloud/.",
            findingNote: "Adobe Creative Cloud is managing app licences or syncing assets.",
            pathPrefixes: ["/Applications/Utilities/Adobe Creative Cloud/", "/Library/Application Support/Adobe/Adobe Desktop Common/"],
            bundleIDs: ["com.adobe.acc.AdobeCreativeCloud"], teamIDs: ["JQ525L2MZD"],
            groundedIn: "https://www.adobe.com/creativecloud.html; file:///Applications/Utilities/Adobe%20Creative%20Cloud"),

        ProcessExplanation(
            id: "creative-photoshop", title: "Adobe Photoshop",
            summary: "Adobe Photoshop, the industry-standard application for photo editing, compositing and digital art.",
            maker: .vendor("Adobe"),
            busyWhen: "While applying filters, rendering effects, or running neural-network-powered features.",
            quit: .app, whatToDo: nil,
            findingNote: "Adobe Photoshop is busy.",
            namePrefixes: ["Adobe Photoshop"],
            bundleIDs: ["com.adobe.Photoshop"], teamIDs: ["JQ525L2MZD"],
            groundedIn: "https://www.adobe.com/products/photoshop.html; file:///Applications"),

        ProcessExplanation(
            id: "creative-illustrator", title: "Adobe Illustrator",
            summary: "Adobe Illustrator, the industry-standard vector graphics editor for logos, illustrations and typography.",
            maker: .vendor("Adobe"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Adobe Illustrator is busy.",
            namePrefixes: ["Adobe Illustrator"],
            bundleIDs: ["com.adobe.illustrator"], teamIDs: ["JQ525L2MZD"],
            groundedIn: "https://www.adobe.com/products/illustrator.html; file:///Applications"),

        ProcessExplanation(
            id: "creative-premiere", title: "Adobe Premiere Pro",
            summary: "Adobe Premiere Pro, a professional non-linear video editor used in film, TV and online content production.",
            maker: .vendor("Adobe"),
            busyWhen: "While rendering previews, encoding exports, or running background media analysis.",
            quit: .app, whatToDo: nil,
            findingNote: "Adobe Premiere Pro is busy.",
            namePrefixes: ["Adobe Premiere Pro"],
            bundleIDs: ["com.adobe.premiere"], teamIDs: ["JQ525L2MZD"],
            groundedIn: "https://www.adobe.com/products/premiere.html; file:///Applications"),

        ProcessExplanation(
            id: "creative-aftereffects", title: "Adobe After Effects",
            summary: "Adobe After Effects, a digital motion graphics and visual effects application for film, TV and the web.",
            maker: .vendor("Adobe"),
            busyWhen: "While rendering compositions, which can fully load all CPU cores for extended periods.",
            quit: .app, whatToDo: nil,
            findingNote: "Adobe After Effects is rendering or compositing.",
            namePrefixes: ["Adobe After Effects"],
            bundleIDs: ["com.adobe.AfterEffects"], teamIDs: ["JQ525L2MZD"],
            groundedIn: "https://www.adobe.com/products/aftereffects.html; file:///Applications"),

        ProcessExplanation(
            id: "creative-acrobat", title: "Adobe Acrobat",
            summary: "Adobe Acrobat, for viewing, creating, editing and signing PDF documents.",
            maker: .vendor("Adobe"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Adobe Acrobat is busy.",
            namePrefixes: ["Adobe Acrobat"],
            bundleIDs: ["com.adobe.Acrobat.Pro"], teamIDs: ["JQ525L2MZD"],
            groundedIn: "https://www.adobe.com/acrobat.html; file:///Applications"),

        ProcessExplanation(
            id: "creative-lightroom", title: "Adobe Lightroom Classic",
            summary: "Adobe Lightroom Classic, a photo library organiser and non-destructive editor for photographers.",
            maker: .vendor("Adobe"),
            busyWhen: "When building previews, running face recognition, or syncing with Lightroom cloud.",
            quit: .app, whatToDo: nil,
            findingNote: "Adobe Lightroom Classic is busy.",
            namePrefixes: ["Adobe Lightroom Classic"],
            bundleIDs: ["com.adobe.lightroomclassic"], teamIDs: ["JQ525L2MZD"],
            groundedIn: "https://www.adobe.com/products/photoshop-lightroom-classic.html; file:///Applications"),

        ProcessExplanation(
            id: "creative-indesign", title: "Adobe InDesign",
            summary: "Adobe InDesign, a desktop publishing application for laying out books, magazines, brochures and digital publications.",
            maker: .vendor("Adobe"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Adobe InDesign is busy.",
            namePrefixes: ["Adobe InDesign"],
            bundleIDs: ["com.adobe.InDesign"], teamIDs: ["JQ525L2MZD"],
            groundedIn: "https://www.adobe.com/products/indesign.html; file:///Applications"),

        // MARK: - Screen recording / capture

        ProcessExplanation(
            id: "creative-cleanshot", title: "CleanShot X",
            summary: "CleanShot X, a screenshot and screen recording tool with annotation, scrolling capture and cloud sharing.",
            maker: .vendor("Makebetter"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "CleanShot X is busy.",
            pathPrefixes: ["/Applications/CleanShot X.app/"],
            bundleIDs: ["pl.makebetter.CleanShot"], teamIDs: ["2FGJJXC25X"],
            groundedIn: "https://cleanshot.com/; file:///Applications/CleanShot%20X.app"),

        ProcessExplanation(
            id: "creative-screenflow", title: "ScreenFlow",
            summary: "ScreenFlow by Telestream, a screen recording and video editing tool for creating tutorials, demos and presentations.",
            maker: .vendor("Telestream"),
            busyWhen: "While recording the screen — it captures every frame in real time.",
            quit: .avoid, whatToDo: "Stop the recording before quitting to avoid losing footage.",
            findingNote: "ScreenFlow is recording the screen.",
            pathPrefixes: ["/Applications/ScreenFlow.app/"],
            bundleIDs: ["com.telestream.screenflow"], teamIDs: ["T25N7FCBVB"],
            groundedIn: "https://www.telestream.net/screenflow/; file:///Applications/ScreenFlow.app"),

        ProcessExplanation(
            id: "creative-screenium", title: "Screenium",
            summary: "Screenium, a screenshot and screen recording utility for macOS.",
            maker: .vendor("Syniumsoftware"),
            busyWhen: nil,
            quit: .app, whatToDo: nil,
            findingNote: "Screenium is busy.",
            pathPrefixes: ["/Applications/Screenium 3.app/", "/Applications/Screenium.app/"],
            bundleIDs: ["com.syniumsoftware.screenium3"],
            groundedIn: "https://www.syniumsoftware.com/screenium; file:///Applications/Screenium%203.app"),

        ProcessExplanation(
            id: "creative-loom", title: "Loom",
            summary: "Loom, a video messaging tool for recording and sharing quick screen and camera recordings with teammates.",
            maker: .vendor("Loom"),
            busyWhen: "While recording the screen or uploading a recording.",
            quit: .app, whatToDo: nil,
            findingNote: "Loom is recording or uploading a screen recording.",
            pathPrefixes: ["/Applications/Loom.app/"],
            bundleIDs: ["com.loom.desktop"],
            groundedIn: "https://www.loom.com/; file:///Applications/Loom.app"),
    ]
}
