import Foundation

// Parsers for the tools the helper runs as root. They live here, not in the helper, so tests and the app share them.
// Each returns nil on output it doesn't recognise: the app then says "couldn't read" rather than showing a guess.

public struct SnapshotSize: Codable, Sendable, Hashable {
    public var name: String
    public var bytes: UInt64
    public init(name: String, bytes: UInt64) { self.name = name; self.bytes = bytes }
}

/// A configuration profile installed for the whole Mac. `scope` is "device".
public struct DeviceProfile: Codable, Sendable, Hashable {
    public var identifier: String
    public var name: String?
    public var scope: String
    public init(identifier: String, name: String?, scope: String) { self.identifier = identifier; self.name = name; self.scope = scope }
}

/// One record from the Background Task Management database (System Settings › Login Items).
public struct BackgroundItem: Codable, Sendable, Hashable {
    public var identifier: String?
    public var name: String?
    /// "app", "login item", "agent", "daemon", "legacy daemon"…, without the hex flags sfltool appends.
    public var type: String
    public var developer: String?
    public var enabled: Bool?
    public var url: String?
    public init(identifier: String?, name: String?, type: String, developer: String?, enabled: Bool?, url: String?) {
        self.identifier = identifier; self.name = name; self.type = type; self.developer = developer
        self.enabled = enabled; self.url = url
    }
}

public enum HelperParsers {
    /// `sfltool dumpbtm`: records start with "#1:", followed by "Key: value" lines. Unknown keys are ignored; a
    /// record without a Type is dropped. nil when there is neither a records header nor a single record.
    public static func backgroundItems(_ sfltoolDumpbtm: String) -> [BackgroundItem]? {
        var items: [BackgroundItem] = []
        var fields: [String: String]?
        var sawHeader = false
        func flush() {
            guard let f = fields, let type = f["Type"] else { return }
            let disposition = (f["Disposition"] ?? "")
                .split(whereSeparator: { "[], ".contains($0) }).map(String.init)
            let enabled: Bool? = disposition.contains("enabled") ? true : (disposition.contains("disabled") ? false : nil)
            items.append(BackgroundItem(identifier: f["Identifier"], name: f["Name"], type: stripFlags(type),
                                        developer: f["Developer Name"], enabled: enabled, url: f["URL"]))
        }
        for raw in sfltoolDumpbtm.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") { sawHeader = true; continue }
            if line.hasPrefix("#"), line.hasSuffix(":"), Int(line.dropFirst().dropLast()) != nil {
                flush()
                fields = [:]
                continue
            }
            guard fields != nil, let colon = line.range(of: ": ") else { continue }
            let key = String(line[..<colon.lowerBound])
            let value = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            if fields?[key] == nil, !value.isEmpty, value != "(null)" { fields?[key] = value }
        }
        flush()
        if items.isEmpty && !sawHeader && fields == nil { return nil }
        return items
    }

    /// "app (0x2)" → "app".
    static func stripFlags(_ s: String) -> String {
        guard let r = s.range(of: " (0x") else { return s }
        return String(s[..<r.lowerBound])
    }

    /// `profiles list -all` as root. Device profiles are the "_computerlevel[n] attribute: profileIdentifier: …"
    /// lines (a following "name:" attribute with the same index names it). "There are no configuration profiles
    /// installed…" is an empty list, not unrecognised output.
    public static func deviceProfiles(_ profilesOutput: String) -> [DeviceProfile]? {
        var ids: [(index: String, id: String)] = []
        var names: [String: String] = [:]
        var recognised = false
        for raw in profilesOutput.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("There are") && line.contains("configuration profiles installed") { recognised = true; continue }
            guard let attr = line.range(of: " attribute: ") else { continue }
            recognised = true
            let owner = line[..<attr.lowerBound]
            guard owner.hasPrefix("_computerlevel[") else { continue }
            let index = String(owner)
            let rest = line[attr.upperBound...]
            guard let colon = rest.range(of: ": ") else { continue }
            let key = rest[..<colon.lowerBound], value = rest[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if key == "profileIdentifier" { ids.append((index, value)) }
            else if key == "name" { names[index] = value }
        }
        guard recognised else { return nil }
        return ids.map { DeviceProfile(identifier: $0.id, name: names[$0.index], scope: "device") }
    }

    /// `tmutil listlocalsnapshots /`: a "Snapshots for …" header, then one snapshot per line. Only lines that also
    /// carry a size ("name (1.2 GB)" or "name (123456 bytes)") are returned, so output without sizes is an empty
    /// list. The size format is unverified until captured from a Developer ID build (see the tests' fixture).
    public static func snapshotSizes(_ tmutilOutput: String) -> [SnapshotSize]? {
        let lines = tmutilOutput.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let header = lines.first, header.hasPrefix("Snapshots for") else { return nil }
        return lines.dropFirst().compactMap { line in
            guard line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) else { return nil }
            let name = String(line[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            let size = line[open.upperBound..<line.index(before: line.endIndex)]
            guard !name.isEmpty, let bytes = byteCount(String(size)) else { return nil }
            return SnapshotSize(name: name, bytes: bytes)
        }
    }

    /// "123456 bytes", "512 KB", "1.2 GB" (decimal units, as tmutil prints them elsewhere).
    static func byteCount(_ s: String) -> UInt64? {
        let parts = s.split(separator: " ")
        guard parts.count == 2, let n = Double(parts[0]), n >= 0 else { return nil }
        let scale: Double
        switch parts[1].uppercased() {
        case "BYTES", "B": scale = 1
        case "KB": scale = 1e3
        case "MB": scale = 1e6
        case "GB": scale = 1e9
        case "TB": scale = 1e12
        default: return nil
        }
        return UInt64(n * scale)
    }

    /// KERN_PROCARGS2 buffer: Int32 argc, the exec path (NUL-terminated), NUL padding, then exactly argc
    /// NUL-terminated arguments (an empty argument is just a NUL, so they are counted, not skipped), then the
    /// environment's strings, ended by an empty string. FlightDeckCore's ProcessDetails uses it too.
    public static func procArgs(_ buf: [UInt8]) -> (args: [String], env: [String])? {
        let size = buf.count
        guard size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0 else { return nil }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }        // exec path
        while i < size && buf[i] == 0 { i += 1 }        // padding
        func next() -> String? {
            guard i < size else { return nil }
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: buf[start..<min(i, size)], as: UTF8.self)
        }
        var args: [String] = []
        while args.count < argc, let a = next() { args.append(a) }
        var env: [String] = []
        while let e = next(), !e.isEmpty { env.append(e) }
        return (args, env)
    }
}
