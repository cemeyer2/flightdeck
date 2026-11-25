// PENDING USER REVIEW: batch 6/12, Kernel, launchd, power, logging
import Foundation

enum ProcessCatalogCore {
    static let part: [ProcessExplanation] = [
        ProcessExplanation(
            id: "kernel-task", title: "macOS kernel",
            summary: "The core of macOS. One of its jobs is managing CPU temperature: when the CPU gets too hot, it makes the CPU less available to the processes using it most.",
            maker: .apple,
            busyWhen: "When the CPU is too hot, even if the Mac doesn't feel hot. It reduces its activity as the CPU cools.",
            quit: .never,
            whatToDo: "It doesn't cause the heat itself. Find the processes using the CPU heavily and quit the ones you don't need.",
            findingNote: "kernel_task is macOS itself. High CPU here is often deliberate: it keeps the CPU busy to slow other work and cool the Mac down.",
            names: ["kernel_task"],
            groundedIn: "https://support.apple.com/en-us/102172"),
        ProcessExplanation(
            id: "core-launchd", title: "launchd service manager",
            summary: "The first process macOS starts. It starts and stops the system's daemons and each user's agents, mostly on demand.",
            maker: .apple,
            busyWhen: nil,
            quit: .never, whatToDo: nil,
            findingNote: "launchd starts and stops system services.",
            names: ["launchd"], paths: ["/sbin/launchd"],
            groundedIn: "x-man-page://8/launchd"),
        ProcessExplanation(
            id: "core-logd", title: "Unified logging daemon",
            summary: "Collects, compresses and stores the log messages that every process writes, and manages the stored history.",
            maker: .apple,
            busyWhen: "When processes write many log messages.",
            quit: .relaunches, whatToDo: nil,
            findingNote: "The logging system is storing log messages, usually because some process is writing a lot of them.",
            names: ["logd"], paths: ["/usr/libexec/logd"],
            groundedIn: "x-man-page://8/logd; file:///System/Library/LaunchDaemons/com.apple.logd.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "core-configd", title: "System configuration daemon",
            summary: "Keeps track of the system's configuration, such as network settings, applies it, and tells apps when it changes.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "configd manages system and network configuration.",
            names: ["configd"], paths: ["/usr/libexec/configd"],
            groundedIn: "x-man-page://8/configd; file:///System/Library/LaunchDaemons/com.apple.configd.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "core-powerd", title: "Power management daemon",
            summary: "Manages the Mac's energy settings.",
            maker: .apple,
            busyWhen: nil,
            quit: .relaunches, whatToDo: nil,
            findingNote: "powerd manages energy settings.",
            names: ["powerd"],
            groundedIn: "x-man-page://1/powerd; file:///System/Library/LaunchDaemons/com.apple.powerd.plist; x-man-page://5/launchd.plist"),
        ProcessExplanation(
            id: "core-sshd", title: "Remote login (SSH) server",
            summary: "The OpenSSH server, which accepts encrypted remote logins. Each connection gets its own sshd process that handles that session.",
            maker: .apple,
            busyWhen: "While someone is connected over SSH.",
            quit: .avoid, whatToDo: nil,
            findingNote: "An SSH connection to this Mac is busy.",
            names: ["sshd"], paths: ["/usr/sbin/sshd"],
            groundedIn: "x-man-page://8/sshd; file:///System/Library/LaunchDaemons/ssh.plist"),
    ]
}
