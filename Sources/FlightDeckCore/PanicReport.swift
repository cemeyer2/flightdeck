import Foundation

// Kernel panic reports for the Restarts & Crashes page. A panic is the kernel stopping the whole Mac because it hit an
// error it can't recover from; macOS restarts and, at the next boot, writes a report into /Library/Logs/DiagnosticReports
// (moved to its Retired subfolder once submitted). Two formats exist: the plain-text ".panic" of macOS 10.x, and the
// ".ips" JSON (bug_type 210) used since macOS 11, sometimes still with a .panic extension. Both are parsed here into the
// panic message, the task that was running, the kernel extensions in the backtrace, and a plain-English culprit.

public struct PanicReport: Sendable, Hashable, Codable, Identifiable {
    /// The broad kind of panic, which decides the explanation and the advice.
    public enum Culprit: String, Sendable, Codable {
        case thirdPartyDriver = "Third-party driver", userspaceWatchdog = "App or service hung", watchdog = "System hang",
             sleepWake = "Sleep/wake failure", hardware = "Hardware error", memory = "Out of kernel memory", gpu = "Graphics",
             kernel = "Kernel error", unknown = "Unknown"
    }
    public var id: String { path }
    public var path: String
    /// When the panic happened (from the report body), or when the report was written if the body has no date.
    public var time: Date
    /// true when `time` is the panic itself; false when it is only the report's write time (the boot after).
    public var timeIsPanic: Bool
    /// The panic message without the "panic(cpu N caller 0x…):" prefix, first line only.
    public var headline: String
    /// The process whose thread panicked ("kernel_task" for the kernel's own threads), when the report names it.
    public var task: String?
    /// Bundle identifiers of kernel extensions in the backtrace, in report order.
    public var kexts: [String]
    /// macOS build ("macOS 14.2.1 (23C71)" or "23C71"), when given.
    public var osVersion: String?
    public var culprit: Culprit
    /// The service named by a userspace watchdog panic ("WindowServer"), or the third-party kext's bundle id.
    public var culpritName: String?

    public var thirdPartyKexts: [String] { kexts.filter { !$0.hasPrefix("com.apple.") } }

    /// One sentence on what happened and what to do, e.g. "Kernel panic in com.example.driver: a third-party driver
    /// crashed the system; update or remove it."
    public var explanation: String {
        switch culprit {
        case .thirdPartyDriver:
            return "Kernel panic in \(culpritName ?? "a third-party driver"): a third-party driver crashed the system. Update or remove it (System Settings › General › Login Items & Extensions, or the vendor's uninstaller)."
        case .userspaceWatchdog:
            let n = culpritName ?? "a system service"
            return "\(n) stopped responding for minutes, so the watchdog restarted the Mac. " + (n == "WindowServer"
                ? "WindowServer draws the screen: a stuck app, display, dock or graphics driver is the usual cause. Update macOS and display/dock software."
                : "Update macOS and any software that extends \(n).")
        case .watchdog:
            return "The whole system hung (the watchdog itself stopped checking in), so the Mac restarted. Common causes: a stuck driver or system extension, a failing disk or accessory. Unplug accessories and update macOS; if it repeats, run Apple Diagnostics."
        case .sleepWake:
            return "The Mac failed to go to sleep or wake up in time. Often a driver or an accessory (dock, display, USB device) that doesn't answer; try without accessories."
        case .hardware:
            return "The processor or another component reported an error. A single one can be a fluke; if it repeats, run Apple Diagnostics and contact Apple."
        case .memory:
            return "The kernel ran out of memory, usually because a driver or the system leaked it. Update macOS and remove old drivers; note which app was busy."
        case .gpu:
            return "The graphics system failed. Update macOS; if it repeats with one app or display, mention that to Apple or the app's developer."
        case .kernel:
            return "The kernel hit an internal error" + (task.map { $0 == "kernel_task" ? "" : " while running \($0)" } ?? "") + ". Update macOS; if it repeats, note what you were doing."
        case .unknown:
            return "The Mac restarted because of a kernel panic. The report doesn't say why in a way FlightDeck recognises."
        }
    }
}

public enum PanicReports {
    /// Where panic reports land. Retired holds reports already sent to Apple; both are readable by admin users.
    public static let directories = ["/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports/Retired"]

    /// Panic reports modified after `since`, newest first. Lists .panic files and the .ips files whose header says
    /// bug_type 210; only the header line of other .ips files is read. Blocking file I/O; call off the main thread.
    public static func scan(since: Date, directories: [String] = directories) -> [PanicReport] {
        var out: [PanicReport] = []
        for d in directories {
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: d), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for u in urls where u.pathExtension == "panic" || u.pathExtension == "ips" {
                guard let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m >= since else { continue }
                // Cheap filter for .ips: the bug type is in the first line.
                if u.pathExtension == "ips", let h = DiagnosticReports.head(u, bytes: 600), !h.contains(#""bug_type":"210""#), !h.contains(#""bug_type" : "210""#) { continue }
                // Panic reports are at most a few MB (mostly backtraces); 4 MB keeps a corrupt file from costing more.
                guard let data = try? FileHandle(forReadingFrom: u).read(upToCount: 4 << 20) else { continue }
                if let r = parse(String(decoding: data, as: UTF8.self), path: u.path, modified: m) { out.append(r) }
            }
        }
        return out.sorted { $0.time > $1.time }
    }

    static let ipsDate: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"; return f }()
    /// The old text format's date line, "Sat Jan  4 10:02:11 2020" (local time, no zone).
    static let textDate: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE MMM d HH:mm:ss yyyy"; return f }()

    /// Parses either format. `modified` is the fallback time. nil when the text has no panic message at all.
    public static func parse(_ text: String, path: String, modified: Date) -> PanicReport? {
        let firstLine = text.prefix { $0 != "\n" }
        var panicString = "", time = modified, timeIsPanic = false, os: String?
        if let hdr = (try? JSONSerialization.jsonObject(with: Data(firstLine.utf8))) as? [String: Any] {
            // .ips: header line, then a JSON body with panicString (Intel and Apple silicon) and/or macOSPanicString
            // (Apple silicon, when the panic was recorded by iBoot). The body can be truncated, so a regex fallback
            // pulls the string out of broken JSON.
            os = hdr["os_version"] as? String
            if let ts = hdr["timestamp"] as? String, let d = ipsDate.date(from: ts) { time = d }
            let bodyText = text.dropFirst(firstLine.count)
            if let body = (try? JSONSerialization.jsonObject(with: Data(bodyText.utf8))) as? [String: Any] {
                let mac = body["macOSPanicString"] as? String ?? ""
                let main = body["panicString"] as? String ?? ""
                panicString = main.contains("panic(") || mac.isEmpty ? main : mac
                if let d = (body["date"] as? String).flatMap(ipsDate.date(from:)) { time = d; timeIsPanic = true }
                os = os ?? body["build"] as? String
            } else if let m = bodyText.firstMatch(of: #/"panicString"\s*:\s*"((?:[^"\\]|\\.)*)/#) {
                panicString = String(m.1).replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
            }
        } else {
            // Plain text: "panic(cpu …" somewhere, a date line near the top, "Mac OS version:" followed by the build.
            panicString = String(text)
            for line in text.split(separator: "\n").prefix(8) {
                if let d = textDate.date(from: line.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)) { time = d; timeIsPanic = true; break }
            }
            if let r = text.range(of: "Mac OS version:\n") { os = text[r.upperBound...].prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces) }
        }
        guard let start = panicString.range(of: "panic(") else { return nil }
        return analyse(String(panicString[start.lowerBound...]), path: path, time: time, timeIsPanic: timeIsPanic, os: os)
    }

    /// Pulls the headline, task and kexts out of a panic string and decides the culprit.
    static func analyse(_ s: String, path: String, time: Date, timeIsPanic: Bool, os: String?) -> PanicReport {
        // "panic(cpu 2 caller 0xffff…): message @file.c:123" → "message"
        var headline = String(s.prefix { $0 != "\n" })
        if let r = headline.range(of: #"^panic\([^)]*\)\s*:\s*"#, options: .regularExpression) { headline.removeSubrange(r) }
        if headline.hasPrefix("\""), let close = headline.dropFirst().firstIndex(of: "\"") { headline = String(headline[headline.index(after: headline.startIndex)..<close]) }
        if let at = headline.range(of: #" ?@[^ ]*:\d+$"#, options: .regularExpression) { headline.removeSubrange(at) }
        headline = headline.trimmingCharacters(in: .whitespaces)

        // The panicked task: "Panicked task 0x…: 191 pages, 8 threads: pid 104: watchdogd" (macOS 11+), or the old
        // "BSD process name corresponding to current thread: kernel_task".
        var task: String?
        if let m = s.firstMatch(of: #/Panicked task 0x[0-9a-fA-F]+:[^\n]*?pid (\d+): ([^\n]+)/#) { task = String(m.2).trimmingCharacters(in: .whitespaces) }
        else if let m = s.firstMatch(of: #/BSD process name corresponding to current thread: ([^\n]+)/#) { task = String(m.1).trimmingCharacters(in: .whitespaces) }

        // Kexts: the lines under "Kernel Extensions in backtrace:" look like "com.vendor.driver(1.2)[UUID]@0x…";
        // "dependency:" lines name what those depend on and aren't suspects.
        var kexts: [String] = []
        if let r = s.range(of: "Kernel Extensions in backtrace:") {
            for line in s[r.upperBound...].split(separator: "\n").prefix(40) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("dependency:") { continue }
                guard let m = t.firstMatch(of: #/^([A-Za-z0-9_.\-]+)\([^)]*\)\[/#) else { if kexts.isEmpty { continue } else { break } }
                kexts.append(String(m.1))
            }
        }

        let lower = headline.lowercased(), all = s.lowercased()
        var culprit = PanicReport.Culprit.unknown, name: String?
        if let m = headline.firstMatch(of: #/(?i)userspace watchdog timeout: no successful checkins from ([A-Za-z0-9_.\-]+)/#) {
            culprit = .userspaceWatchdog; name = String(m.1)
        } else if lower.contains("watchdog timeout") || lower.contains("watchdog") && lower.contains("no checkins") {
            culprit = .watchdog
        } else if let k = kexts.first(where: { !$0.hasPrefix("com.apple.") }) {
            culprit = .thirdPartyDriver; name = k
        } else if lower.contains("sleep") && (lower.contains("wake") || lower.contains("transition")) {
            culprit = .sleepWake
        } else if lower.contains("serror") || lower.contains("machine check") || lower.contains("socd")
                    || lower.contains("is not responding") {
            culprit = .hardware
        } else if lower.contains("zone_map") || lower.contains("zalloc") || lower.contains("memory exhausted") || lower.contains("jetsam") {
            culprit = .memory
        } else if lower.contains("agx") || lower.contains("gpu") || all.contains("com.apple.agx") {
            culprit = .gpu
        } else if lower.contains("data abort") || lower.contains("page fault") || lower.contains("kernel trap") || lower.contains("assertion failed") {
            culprit = .kernel
        }
        return PanicReport(path: path, time: time, timeIsPanic: timeIsPanic, headline: headline.isEmpty ? "Kernel panic" : String(headline.prefix(300)),
                           task: task, kexts: kexts, osVersion: os, culprit: culprit, culpritName: name)
    }
}
