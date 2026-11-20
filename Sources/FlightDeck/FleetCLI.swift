// Developer-only Fleet modes, for checking two FlightDeck processes talking without a second Mac:
//   FlightDeck --fleet-serve <port>             serve this Mac's real samples on 127.0.0.1:<port> (no Bonjour, memory-only
//                                               pairing store), pairing open, the code printed; runs until killed
//   FlightDeck --fleet-query <host:port> <code> pair with that server, then print its status JSON
import Foundation
import FlightDeckCore

@MainActor
enum FleetCLI {
    static func serve(port raw: String) -> Never {
        guard let port = UInt16(raw) else { CLI.fail("--fleet-serve needs a port") }
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = FleetStore(dir: nil)
        final class Live: @unchecked Sendable { let lock = NSLock(); var snap: Snapshot?; var findings: [Finding] = []; var history: [FleetPoint] = [] }
        let live = Live()
        let identity = FleetService.identity(id: store.instanceID, hasBattery: false)
        let server = FleetServer(store: store, hostName: identity.name) {
            live.lock.withLock {
                let up = Sysctl.timeval("kern.boottime").map { Date().timeIntervalSince($0) }
                let id = FleetService.identity(id: store.instanceID, hasBattery: live.snap?.power.battery != nil)
                return FleetStatus.build(identity: id, snapshot: live.snap, findings: live.findings, incidents: [], history: live.history,
                                         uptime: up, redaction: .current)
            }
        }
        let listener = FleetListener(server: server, port: port, advertise: false, loopbackOnly: true)
        listener.start { err in
            if let err { print("couldn't listen: \(err)"); exit(1) }
            print("serving 127.0.0.1:\(port); pairing code \(server.openPairing())")
        }
        Thread.detachNewThread {
            let sampler = Sampler(), analyzer = Analyzer()
            _ = sampler.sample()
            var shown: String?
            while true {
                Thread.sleep(forTimeInterval: 2)
                // A failed attempt replaces the code; a success closes pairing (reopened here so more viewers can try).
                let code = server.pairingState().code ?? server.openPairing()
                if code != shown, shown != nil { print("pairing code now \(code)") }
                shown = code
                let s = sampler.sample(), f = analyzer.ingest(s)
                live.lock.withLock { live.snap = s; live.findings = f; live.history = Array((live.history + [FleetPoint(s)]).suffix(60)) }
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    static func query(_ target: String, code: String) -> Never {
        let parts = target.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { CLI.fail("--fleet-query needs host:port and a code") }
        let client = FleetClient(host: String(parts[0]), port: port)
        let viewerID = UUID().uuidString
        Task {
            do {
                let hello = try await client.hello()
                print("hello: \(hello.name) (pairing \(hello.pairingOpen ? "open" : "closed"))")
                let host = try await client.pair(code: code, viewerID: viewerID, viewerName: "fleet-query")
                print("paired with \(host.name)")
                let s = try await client.status(host: host, viewerID: viewerID)
                let e = JSONEncoder.fleet; e.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try e.encode(s), as: UTF8.self))
                exit(0)
            } catch { print("failed: \(error)"); exit(1) }
        }
        RunLoop.main.run()
        exit(0)
    }
}
