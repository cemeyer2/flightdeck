// Lenient JSON access for UniFi responses. Field names, types and presence differ between UniFi Network versions
// (a number may arrive as 42, 42.0 or "42"; a flag as true or 1), so instead of strict Codable structs, which would reject
// a whole response over one unexpected field, decoders read through these accessors: a missing or mistyped field is
// simply nil, and the rest of the record still decodes.
import Foundation

/// A JSON object with forgiving typed accessors.
struct JObj {
    let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }

    func str(_ k: String) -> String? {
        switch raw[k] {
        case let s as String: return s.isEmpty ? nil : s
        // JSON booleans also bridge to NSNumber; CFBoolean's type ID tells them apart so `true` doesn't become "1".
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): return n.stringValue
        default: return nil
        }
    }
    func double(_ k: String) -> Double? {
        switch raw[k] {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): return n.doubleValue.isFinite ? n.doubleValue : nil
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
    func int(_ k: String) -> Int? { double(k).flatMap { $0.magnitude < 1e15 ? Int($0) : nil } }
    func uint64(_ k: String) -> UInt64? { double(k).flatMap { $0 >= 0 && $0 < 1.8e19 ? UInt64($0) : nil } }
    /// true/false, 1/0 or "true"/"false".
    func bool(_ k: String) -> Bool? {
        switch raw[k] {
        case let b as Bool: return b
        case let n as NSNumber: return n.intValue != 0
        case let s as String: return ["true", "1", "yes"].contains(s.lowercased()) ? true : ["false", "0", "no"].contains(s.lowercased()) ? false : nil
        default: return nil
        }
    }
    func obj(_ k: String) -> JObj? { (raw[k] as? [String: Any]).map(JObj.init) }
    func array(_ k: String) -> [JObj] { (raw[k] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).map(JObj.init) } }
    func has(_ k: String) -> Bool { raw[k] != nil && !(raw[k] is NSNull) }
}

enum UniFiJSON {
    /// The top-level object of a response, or nil if it isn't a JSON object.
    static func object(_ data: Data) -> JObj? {
        (try? JSONSerialization.jsonObject(with: data)).flatMap { $0 as? [String: Any] }.map(JObj.init)
    }
    /// Records of a list response. Classic responses wrap them as `{"meta": {"rc": "ok"}, "data": [...]}`, integration
    /// responses as `{"offset":0, "limit":25, "count":n, "totalCount":n, "data": [...]}`, and a few endpoints return a
    /// bare array.
    static func records(_ data: Data) -> [JObj]? {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let a = any as? [Any] { return a.compactMap { ($0 as? [String: Any]).map(JObj.init) } }
        guard let o = any as? [String: Any] else { return nil }
        return JObj(o).array("data")
    }
    /// The classic API's error, if the envelope says `"rc": "error"` (e.g. "api.err.LoginRequired").
    static func classicError(_ data: Data) -> String? {
        guard let meta = object(data)?.obj("meta"), meta.str("rc") == "error" else { return nil }
        return meta.str("msg") ?? "error"
    }
}

/// Shared helpers (MAC normalization, OUI matching, Wi-Fi naming).
public enum UniFi {
    /// Lowercase, colon-separated, zero-padded: "74ACB95E21A9", "74-ac-b9-5e-21-a9" and "74:ac:b9:5e:21:a9" all become
    /// "74:ac:b9:5e:21:a9". `arp` prints octets without leading zeros ("0:1a:…"), which is padded too.
    public static func normalizeMAC(_ s: String) -> String {
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
        let parts = t.split(whereSeparator: { $0 == ":" || $0 == "-" })
        if parts.count == 6 { return parts.map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":") }
        let hex = t.filter(\.isHexDigit)
        guard hex.count == 12 else { return t }
        var out = "", i = hex.startIndex
        for n in 0..<6 { let j = hex.index(i, offsetBy: 2); out += (n > 0 ? ":" : "") + hex[i..<j]; i = j }
        return out
    }

    /// Classic `radio_proto` ("ax", "ac", "be"…) to a readable standard.
    public static func wifiStandard(proto: String?) -> String? {
        guard let p = proto?.lowercased() else { return nil }
        switch p {
        case "be": return "802.11be (Wi-Fi 7)"
        case "ax": return "802.11ax (Wi-Fi 6/6E)"
        case "ac": return "802.11ac (Wi-Fi 5)"
        case "ng", "n", "na": return "802.11n (Wi-Fi 4)"
        case "a": return "802.11a"; case "g": return "802.11g"; case "b": return "802.11b"
        default: return p
        }
    }

    /// Classic radio names ("ng" = 2.4 GHz, "na" = 5 GHz, "6e" = 6 GHz) to a band label.
    public static func band(radio: String?) -> String? {
        switch radio?.lowercased() {
        case "ng": "2.4 GHz"; case "na": "5 GHz"; case "6e": "6 GHz"; case "wifi6e": "6 GHz"
        default: nil
        }
    }

    /// Band from a channel number, used when the console gives only the channel. Channels 1–14 are 2.4 GHz;
    /// higher numbers are 5 GHz unless the console reports 6 GHz separately (6 GHz channel numbers overlap 5 GHz ones).
    public static func band(channel: Int?) -> String? {
        guard let c = channel, c > 0 else { return nil }
        return c <= 14 ? "2.4 GHz" : "5 GHz"
    }
}
