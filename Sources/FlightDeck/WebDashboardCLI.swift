// Developer-only web dashboard mode, for looking at the page (and taking its screenshot) without turning the
// dashboard on in the app:
//   FlightDeck --web-demo <port>   serve demo data on 127.0.0.1:<port> until killed
import Foundation
import FlightDeckCore

@MainActor
enum WebDashboardCLI {
    /// Demo frames and findings; touched only on the main actor.
    private static var frames: [Snapshot] = [], findings: [Finding] = []

    static func document(history: Bool, latest: Bool) -> Data {
        let now = Date(), snap = frames.last
        var i = WebDashboardInputs(snapshot: snap, findings: findings, incidents: Demo.incidents(now),
                                   // Invented identity too, so nothing on the page describes this Mac.
                                   displayName: "MacBook Pro", modelName: "MacBook Pro", hardwareModel: "Mac16,7",
                                   macOS: "26.1", appVersion: MCPEndpoint.version, uptime: 3 * 86400 + 4 * 3600,
                                   paused: false, intervalS: 2, demo: true, redaction: .current)
        if history { i.history = .points(WebDashboardState.history(frames: frames, now: now)) }
        if latest, let snap { i.point = WebPoint(snap) }
        return WebDashboardState.encode(WebDashboardState.build(i))
    }

    static func serveDemo(port raw: String) -> Never {
        guard let port = UInt16(raw) else { CLI.fail("--web-demo needs a port") }
        setvbuf(stdout, nil, _IOLBF, 0)
        let sampler = Sampler(), analyzer = Analyzer()
        _ = sampler.sample()
        let template = sampler.sample()
        // 30 minutes of demo frames, one every 30 s, so the sparklines start full.
        let start = Date().addingTimeInterval(-1800)
        frames = (0..<60).map { Demo.frame(template: template, i: $0, time: start.addingTimeInterval(Double($0) * 30)) }
        findings = frames.map { analyzer.ingest($0) }.last ?? []

        let ctx = WebNetworkContext.read(localHostName: nil, tailscaleProcessRunning: false, advanced: false)
        let server = WebDashboardServer(port: port, loopbackOnly: true, context: ctx, allowlist: .parse(""),
                                        provider: { withHistory, reply in
                                            Task { @MainActor in reply(WebDashboardCLI.document(history: withHistory, latest: false)) }
                                        },
                                        log: { print($0) })
        server.start { err in
            if let err { print("couldn't listen: \(err)"); exit(1) }
            print("serving demo data on http://127.0.0.1:\(port)/")
        }
        var i = frames.count
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let s = Demo.frame(template: template, i: i, time: Date())
                i += 1
                frames = Array((frames + [s]).suffix(900)); findings = analyzer.ingest(s)
                server.publish(document(history: false, latest: true))
            }
        }
        RunLoop.main.run()
        exit(0)
    }
}
