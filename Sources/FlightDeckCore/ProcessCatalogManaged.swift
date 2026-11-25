// PENDING USER REVIEW: batch 12/12, Corporate security and MDM (managed)
import Foundation

enum ProcessCatalogManaged {
    static let part: [ProcessExplanation] = [
        ProcessExplanation(
            id: "managed-crowdstrike-falcon", title: "CrowdStrike Falcon",
            summary: "CrowdStrike Falcon, endpoint protection and detection (EDR) software that watches for and blocks malicious software. Your organisation installs and manages it.",
            maker: .vendor("CrowdStrike"),
            busyWhen: nil,
            quit: .avoid, whatToDo: "Contact your IT team.",
            findingNote: "CrowdStrike Falcon, your organisation's security software, is busy.", managed: true,
            pathPrefixes: ["/Applications/Falcon.app/"], bundleIDs: ["com.crowdstrike.falcon.App"], teamIDs: ["X9E956P446"],
            groundedIn: "https://www.crowdstrike.com/en-us/platform/endpoint-security/; file:///Applications/Falcon.app"),
        ProcessExplanation(
            id: "managed-zscaler", title: "Zscaler Client Connector",
            summary: "Zscaler Client Connector, a lightweight agent that is part of your organisation's Zscaler network security service. Your organisation installs and manages it.",
            maker: .vendor("Zscaler"),
            busyWhen: nil,
            quit: .avoid, whatToDo: "Contact your IT team.",
            findingNote: "Zscaler, your organisation's network security software, is busy.", managed: true,
            pathPrefixes: ["/Applications/Zscaler/Zscaler.app/", "/Library/Application Support/Zscaler/"],
            groundedIn: "https://www.zscaler.com/products-and-solutions/zscaler-client-connector; file:///Applications/Zscaler/Zscaler.app; file:///Library/Application%20Support/Zscaler"),
        ProcessExplanation(
            id: "managed-jamf", title: "Jamf device management",
            summary: "Jamf, which your organisation uses to manage and secure this Mac. Self Service lets you install apps and updates your organisation offers.",
            maker: .vendor("Jamf"),
            busyWhen: nil,
            quit: .avoid, whatToDo: "Contact your IT team.",
            findingNote: "Jamf, your organisation's device management software, is busy.", managed: true,
            pathPrefixes: ["/Library/Application Support/JAMF/", "/Library/Application Support/JamfAppInstallers/", "/Applications/Self Service.app/"], bundleIDs: ["com.jamf.selfserviceplus"], teamIDs: ["483DWKW443"],
            groundedIn: "https://www.jamf.com/products/jamf-pro/; file:///Library/Application%20Support/JAMF; file:///Applications/Self%20Service.app"),
        ProcessExplanation(
            id: "managed-globalprotect", title: "GlobalProtect VPN",
            summary: "Palo Alto Networks GlobalProtect, which connects the Mac to your organisation's network through a secure tunnel. Your organisation installs and manages it.",
            maker: .vendor("Palo Alto Networks"),
            busyWhen: nil,
            quit: .avoid, whatToDo: "Contact your IT team.",
            findingNote: "GlobalProtect, your organisation's VPN, is busy.", managed: true,
            pathPrefixes: ["/Applications/GlobalProtect.app/"], bundleIDs: ["com.paloaltonetworks.GlobalProtect.client"], teamIDs: ["PXPZ95SK77"],
            groundedIn: "https://www.paloaltonetworks.com/sase/globalprotect; file:///Applications/GlobalProtect.app"),
        ProcessExplanation(
            id: "managed-cyberark-epm", title: "CyberArk Endpoint Privilege Manager",
            summary: "CyberArk Endpoint Privilege Manager, which replaces standing administrator rights with approved, temporary elevation for specific apps and tasks. Your organisation installs and manages it.",
            maker: .vendor("CyberArk"),
            busyWhen: nil,
            quit: .avoid, whatToDo: "Contact your IT team.",
            findingNote: "CyberArk EPM, your organisation's privilege management software, is busy.", managed: true,
            pathPrefixes: ["/Applications/CyberArk EPM.app/"], bundleIDs: ["com.cyberark.CyberArkEPM"], teamIDs: ["DF8U2CCCD8"],
            groundedIn: "https://www.paloaltonetworks.com/idira/human/endpoint-privilege-manager; file:///Applications/CyberArk%20EPM.app"),
        ProcessExplanation(
            id: "managed-defender", title: "Microsoft Defender for Endpoint",
            summary: "Microsoft Defender for Endpoint, which helps your organisation prevent, detect and respond to threats on the Mac, including real-time protection against malware.",
            maker: .vendor("Microsoft"),
            busyWhen: nil,
            quit: .avoid, whatToDo: "Contact your IT team.",
            findingNote: "Microsoft Defender, your organisation's security software, is busy.", managed: true,
            pathPrefixes: ["/Applications/Microsoft Defender.app/"],
            groundedIn: "https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-endpoint-mac; https://learn.microsoft.com/en-us/defender-endpoint/mac-resources"),
    ]
}
