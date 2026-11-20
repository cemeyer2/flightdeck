// End to end through the built `FlightDeck --mcp` binary: a client subscribes over stdio and a notification arrives
// (the event comes from the FLIGHTDECK_MCP_INJECT_EVENT test hook, since a real incident can't be made on demand).
import XCTest
@testable import FlightDeckCore

final class MCPStdioEventTests: XCTestCase {
    func testSubscribeOverStdioDeliversANotification() async throws {
        let bin = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("FlightDeck")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else { throw XCTSkip("FlightDeck binary not built at \(bin.path)") }
        let p = Process()
        p.executableURL = bin; p.arguments = ["--mcp"]
        let inject = #"{"event":"incident_opened","severity":"warning","title":"Xcode is using 412% CPU","app":"Xcode","since":"2026-11-19T10:00:00-08:00","key":"cpu:Xcode"}"#
        p.environment = ProcessInfo.processInfo.environment.merging(["FLIGHTDECK_MCP_STANDALONE": "1", "FLIGHTDECK_MCP_INJECT_EVENT": inject]) { _, b in b }
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        let msgs = [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#,
                    #"{"jsonrpc":"2.0","id":2,"method":"resources/subscribe","params":{"uri":"flightdeck://incidents"}}"#]
        input.fileHandleForWriting.write(Data((msgs.joined(separator: "\n") + "\n").utf8))
        // Read until the notification, or give up after 20 s.
        let watchdog = Task { try await Task.sleep(nanoseconds: 20_000_000_000); p.terminate() }
        var seen: [JSON] = []
        for try await line in output.fileHandleForReading.bytes.lines {
            let j = try JSON.parse(Data(line.utf8))
            seen.append(j)
            if j["method"] != nil { break }
        }
        watchdog.cancel()
        try input.fileHandleForWriting.close()
        let ids = seen.compactMap { $0["id"]?.int }
        XCTAssertEqual(Set(ids), [1, 2])
        XCTAssertEqual(seen.first { $0["id"]?.int == 1 }?["result"]?["capabilities"]?["resources"]?["subscribe"]?.bool, true)
        let n = try XCTUnwrap(seen.last)
        XCTAssertEqual(n["method"]?.string, "notifications/resources/updated")
        XCTAssertEqual(n["params"]?["uri"]?.string, MCPResources.incidents)
        XCTAssertEqual(MCPResources.event(in: n)?.app, "Xcode")
    }
}
