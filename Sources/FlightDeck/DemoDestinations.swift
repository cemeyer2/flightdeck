// Demo mode's Destinations page: 30 days of invented per-app destinations. Slack talks to slack.com, the rest to
// reserved ".example" and ".home.arpa" names and to documentation-range IPs (192.0.2.0/24, 198.51.100.0/24,
// 203.0.113.0/24, 2001:db8::/32), so no real host appears. Today a "Mystery Helper" contacts an unnamed IP for the
// first time and Photos moves an unusual amount to the NAS. Nothing here reads this Mac's traffic.
import Foundation
import FlightDeckCore

extension Demo {
    /// One invented destination of one app: bytes per day around `mb`, from `fromDay` days ago (0 = today only).
    private struct DemoDest: Sendable {
        var app: String, name: String, ip: String, host: String?, port: UInt16, proto = "tcp"
        var mbIn: Double, mbOut: Double, conns: Int, fromDay = 29, todayFactor = 1.0, everyOtherDay = false
    }

    nonisolated private static let demoDests: [DemoDest] = [
        DemoDest(app: "/Applications/Slack.app", name: "Slack", ip: "203.0.113.10", host: "wss-primary.slack.com", port: 443, mbIn: 18, mbOut: 2.4, conns: 6),
        DemoDest(app: "/Applications/Slack.app", name: "Slack", ip: "203.0.113.11", host: "edgeapi.slack.com", port: 443, mbIn: 9, mbOut: 1.1, conns: 14),
        DemoDest(app: "/Applications/Slack.app", name: "Slack", ip: "203.0.113.12", host: "files.slack.com", port: 443, mbIn: 22, mbOut: 6, conns: 4, everyOtherDay: true),
        DemoDest(app: "/Applications/Safari.app", name: "Safari", ip: "198.51.100.20", host: "www.news.example", port: 443, proto: "quic", mbIn: 85, mbOut: 3, conns: 22),
        DemoDest(app: "/Applications/Safari.app", name: "Safari", ip: "198.51.100.21", host: "video.cdn.example", port: 443, proto: "quic", mbIn: 640, mbOut: 9, conns: 8, everyOtherDay: true),
        DemoDest(app: "/Applications/Safari.app", name: "Safari", ip: "2001:db8:4::15", host: "docs.office-suite.example", port: 443, mbIn: 12, mbOut: 4, conns: 9, fromDay: 0),
        DemoDest(app: "/System/Applications/Mail.app", name: "Mail", ip: "192.0.2.25", host: "imap.mail.example", port: 993, mbIn: 14, mbOut: 0.6, conns: 3),
        DemoDest(app: "/System/Applications/Mail.app", name: "Mail", ip: "192.0.2.26", host: "smtp.mail.example", port: 587, mbIn: 0.2, mbOut: 3.5, conns: 2, everyOtherDay: true),
        DemoDest(app: "/System/Applications/Music.app", name: "Music", ip: "198.51.100.40", host: "stream.music-service.example", port: 443, mbIn: 120, mbOut: 1.5, conns: 5),
        DemoDest(app: "/System/Applications/Photos.app", name: "Photos", ip: "192.168.1.20", host: "nas.home.arpa", port: 445, mbIn: 6, mbOut: 70, conns: 2, todayFactor: 34),
        DemoDest(app: "/System/Applications/Photos.app", name: "Photos", ip: "203.0.113.60", host: "upload.photo-cloud.example", port: 443, mbIn: 2, mbOut: 45, conns: 3),
        DemoDest(app: "proc:Mystery Helper", name: "Mystery Helper", ip: "198.51.100.77", host: nil, port: 8443, mbIn: 0.4, mbOut: 9.2, conns: 1, fromDay: 0),
        DemoDest(app: "proc:Mystery Helper", name: "Mystery Helper", ip: "192.0.2.99", host: nil, port: 4444, mbIn: 0.1, mbOut: 0.8, conns: 3, fromDay: 0),
        DemoDest(app: "proc:mDNSResponder", name: "mDNSResponder", ip: "224.0.0.251", host: nil, port: 5353, proto: "udp", mbIn: 1.2, mbOut: 0.3, conns: 2),
        DemoDest(app: "proc:Printer Utility", name: "Printer Utility", ip: "192.168.1.31", host: "printer.home.arpa", port: 631, mbIn: 0.1, mbOut: 0.2, conns: 1, everyOtherDay: true),
    ]

    /// The last 30 days, oldest first; today ends an hour before `now` (or at it, just after midnight).
    nonisolated static func destinationDays(now: Date = Date()) -> [DestinationDay] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0..<30).reversed().map { k -> DestinationDay in
            let start = cal.date(byAdding: .day, value: -k, to: today)!
            let end = k == 0 ? max(start.addingTimeInterval(60), now.addingTimeInterval(-3600)) : start.addingTimeInterval(22 * 3600)
            var rows: [DestinationRow] = []
            for (i, d) in demoDests.enumerated() where k <= d.fromDay && !(d.everyOtherDay && k % 2 == 1) {
                // Deterministic wobble so days differ without randomness.
                let wobble = 0.75 + 0.5 * (0.5 + 0.5 * sin(Double(k * 7 + i) / 3.1))
                let f = (k == 0 ? d.todayFactor : 1) * wobble
                let scope = AddressScope.of(d.ip) ?? .publicInternet
                let first = min(start.addingTimeInterval(Double(8 * 3600 + i * 700)), end)
                var r = DestinationRow(app: d.app, appName: d.name, ip: d.ip, scope: scope, host: d.host,
                                       nameSource: d.host != nil ? .reverseDNS : (scope.lookUp ? .none : .notLookedUp),
                                       first: first, last: end)
                r.bytesIn = UInt64(d.mbIn * f * 1_000_000); r.bytesOut = UInt64(d.mbOut * f * 1_000_000)
                r.connections = max(1, Int(Double(d.conns) * wobble)); r.ports = [d.port]; r.protos = [d.proto]
                rows.append(r)
            }
            return DestinationDay(start: start, rows: rows, firstCounted: start.addingTimeInterval(7 * 3600), lastCounted: end)
        }
    }

    /// The known list as the tracker would have built it from those days.
    nonisolated static func destinationKnown(now: Date = Date()) -> KnownDestinations {
        var k = KnownDestinations()
        // Mystery Helper existed (quietly, talking to nothing kept) for weeks, so today's contacts are "new", not learning.
        k.note(app: "proc:Mystery Helper", name: "Mystery Helper", dest: "localhost", at: now.addingTimeInterval(-20 * 86_400))
        for d in destinationDays(now: now) { for r in d.rows { k.note(app: r.app, name: r.appName, dest: r.destinationKey, at: r.first) } }
        return k
    }
}
