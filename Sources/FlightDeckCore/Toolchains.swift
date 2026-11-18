import Foundation

// Installed toolchains for the Developer destination: Xcode and the common language runtimes, each probed only if
// it is installed, with a timeout, and without tripping the traps macOS sets for `--version` probes:
//  - /usr/bin/swift, /usr/bin/python3, /usr/bin/git … are xcrun stubs. With no developer directory selected, running
//    one pops up the "install the command line developer tools" dialog, so they are only run when `xcode-select -p`
//    names a directory that exists.
//  - /usr/bin/java is a stub that opens a "you need a JDK" dialog when none is installed, so it is only run when
//    `/usr/libexec/java_home` finds one.
//  - Version-manager shims (pyenv, rbenv, nodenv, asdf) would start the manager, which can be slow or install
//    things; they are never run. The manager's global version file is read instead, and the row says so.

/// One toolchain row. `version` is nil when it couldn't be determined, with `note` saying why.
public struct Toolchain: Identifiable, Hashable, Sendable {
    public var id: String { tool }
    public var tool: String
    public var version: String?
    public var path: String?
    public var note: String?
    public init(tool: String, version: String?, path: String?, note: String?) {
        self.tool = tool; self.version = version; self.path = path; self.note = note
    }
}

public enum Toolchains {
    /// (display name, executable, arguments). Java prints its version on stderr, which `ToolRun.reason` doesn't
    /// read, so the probe below looks at both streams.
    static let probes: [(String, String, [String])] = [
        ("Swift", "swift", ["--version"]), ("Node.js", "node", ["--version"]), ("Python", "python3", ["--version"]),
        ("Go", "go", ["version"]), ("Rust", "rustc", ["--version"]), ("Java", "java", ["-version"]), ("Ruby", "ruby", ["--version"]),
    ]

    /// Probes every toolchain concurrently. Blocking (up to the 5 s per-tool timeout); call off the main thread.
    public static func detect() -> [Toolchain] {
        let devDir = developerDirectory()
        var rows = [Toolchain?](repeating: nil, count: probes.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: probes.count) { i in
            let (name, exe, args) = probes[i]
            let r = probe(name: name, exe: exe, args: args, devDir: devDir)
            lock.lock(); rows[i] = r; lock.unlock()
        }
        return xcode(devDir) + rows.compactMap { $0 }
    }

    /// The selected developer directory, or nil when none is selected or it no longer exists.
    static func developerDirectory() -> String? {
        guard let r = DevShell.run("/usr/bin/xcode-select", ["-p"], timeout: 5), r.ok else { return nil }
        let d = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return !d.isEmpty && FileManager.default.fileExists(atPath: d) ? d : nil
    }

    /// Xcode rows: the selected developer directory, plus `xcodebuild -version` when that is a full Xcode (the
    /// Command Line Tools alone have no xcodebuild and say so instead of answering). Other Xcode apps in
    /// /Applications are listed by their bundle version, read from Info.plist without launching anything.
    static func xcode(_ devDir: String?) -> [Toolchain] {
        guard let devDir else {
            return [Toolchain(tool: "Xcode", version: nil, path: nil, note: "no developer directory selected (xcode-select -p failed)")]
        }
        var rows: [Toolchain] = []
        if devDir.hasSuffix("/CommandLineTools") {
            rows.append(Toolchain(tool: "Xcode", version: nil, path: devDir, note: "only the Command Line Tools are selected"))
        } else if let r = DevShell.run("/usr/bin/xcodebuild", ["-version"], timeout: 10), r.ok, let v = xcodeVersion(r.stdout) {
            rows.append(Toolchain(tool: "Xcode (selected)", version: v, path: devDir, note: nil))
        } else {
            rows.append(Toolchain(tool: "Xcode (selected)", version: nil, path: devDir, note: "xcodebuild -version didn't answer (license not accepted?)"))
        }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        for app in apps.sorted() where app.hasPrefix("Xcode") && app.hasSuffix(".app") {
            let path = "/Applications/" + app
            if devDir.hasPrefix(path + "/") { continue }   // already the selected one
            let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
            rows.append(Toolchain(tool: (app as NSString).deletingPathExtension, version: info?["CFBundleShortVersionString"] as? String,
                                  path: path, note: info == nil ? "Info.plist unreadable" : "not selected"))
        }
        return rows
    }

    static func probe(name: String, exe: String, args: [String], devDir: String?) -> Toolchain? {
        guard let path = DevShell.find(exe) else { return nil }
        if let manager = shimManager(path) {
            let (v, file) = managerVersion(manager, tool: exe)
            return Toolchain(tool: name, version: v, path: path,
                             note: v != nil ? "\(manager) global version from \(file); the shim wasn't run" : "\(manager) shim; not run (it would start \(manager)) and no global version is set")
        }
        let stub = path.hasPrefix("/usr/bin/")
        if stub && exe == "java" {
            guard let jh = DevShell.run("/usr/libexec/java_home", [], timeout: 5), jh.ok else { return nil }   // no JDK: no row
        } else if stub && exe != "ruby" && devDir == nil {
            return Toolchain(tool: name, version: nil, path: path, note: "not run: without developer tools this stub opens an install dialog")
        }
        guard let r = DevShell.run(path, args, timeout: 5) else { return Toolchain(tool: name, version: nil, path: path, note: "couldn't be started") }
        if r.timedOut { return Toolchain(tool: name, version: nil, path: path, note: "timed out after 5 s") }
        let v = version(tool: exe, output: r.stdout + "\n" + r.stderr)
        return Toolchain(tool: name, version: v, path: path, note: v == nil ? "unrecognised output: \(r.reason)" : nil)
    }

    /// The version manager owning a shim path, or nil.
    static func shimManager(_ path: String) -> String? {
        for m in ["pyenv", "rbenv", "nodenv", "asdf"] where path.contains("/.\(m)/shims/") { return m }
        return nil
    }

    /// Reads a version manager's global version without running it: pyenv/rbenv/nodenv keep it in `~/.<m>/version`,
    /// asdf in `~/.tool-versions` as "<plugin> <version>" lines.
    static func managerVersion(_ manager: String, tool: String) -> (String?, String) {
        let home = NSHomeDirectory()
        if manager == "asdf" {
            let plugin = ["python3": "python", "node": "nodejs", "go": "golang", "rustc": "rust"][tool] ?? tool
            let text = (try? String(contentsOfFile: home + "/.tool-versions", encoding: .utf8)) ?? ""
            return (asdfVersion(text, plugin: plugin), "~/.tool-versions")
        }
        let text = (try? String(contentsOfFile: "\(home)/.\(manager)/version", encoding: .utf8)) ?? ""
        let v = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
        return (v.flatMap { $0.isEmpty ? nil : $0 }, "~/.\(manager)/version")
    }

    static func asdfVersion(_ text: String, plugin: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.split(separator: " ")
            if t.count >= 2, t[0] == plugin { return String(t[1]) }
        }
        return nil
    }

    /// Pulls the version out of a tool's version banner. Each tool words it differently:
    ///   swift:  "swift-driver version: 1.120.5 Apple Swift version 6.1 (swiftlang-…)"  → 6.1 (not the driver's)
    ///   node:   "v22.3.0"                          go:    "go version go1.22.4 darwin/arm64" → 1.22.4
    ///   python: "Python 3.12.4"                    rustc: "rustc 1.79.0 (129f3b996 2024-06-10)"
    ///   java:   "openjdk version \"21.0.3\" 2024-04-16" or "java version \"1.8.0_402\""
    ///   ruby:   "ruby 3.3.0 (2023-12-25 revision 5124f9ac75) [arm64-darwin23]"
    public static func version(tool: String, output: String) -> String? {
        switch tool {
        case "swift": return firstMatch(#"Swift version ([0-9][0-9A-Za-z.\-]*)"#, output)
        case "go": return firstMatch(#"go version go([0-9][0-9A-Za-z.\-]*)"#, output)
        case "java": return firstMatch(#"version "([^"]+)""#, output)
        case "node": return firstMatch(#"\bv?([0-9]+\.[0-9]+\.[0-9]+)"#, output)
        default: return firstMatch(#"\b([0-9]+\.[0-9]+(?:\.[0-9]+)?(?:[-+._][0-9A-Za-z]+)*)"#, output)
        }
    }

    /// "Xcode 16.0\nBuild version 16A242d" → "16.0 (16A242d)".
    public static func xcodeVersion(_ out: String) -> String? {
        guard let v = firstMatch(#"Xcode ([0-9][0-9.]*)"#, out) else { return nil }
        return firstMatch(#"Build version (\S+)"#, out).map { "\(v) (\($0))" } ?? v
    }

    static func firstMatch(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
