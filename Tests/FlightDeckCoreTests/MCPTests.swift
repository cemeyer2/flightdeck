// MCP server tests, protocol half: JSON serialisation, JSON-RPC parsing and errors, version handling (legacy
// `initialize` and modern per-request `_meta`), header/body validation, and the `initialize` / `tools/list` shapes.
// Tool output is in MCPToolTests.swift; transports in MCPTransportTests.swift.
import XCTest
@testable import FlightDeckCore

/// A tool provider with one tool that echoes its arguments, so protocol tests don't depend on real data.
struct EchoTools: MCPToolProvider {
    var specs: [MCPToolSpec] { [MCPToolSpec(name: "echo", title: "Echo", description: "Echoes.", inputSchema: ["type": "object"])] }
    func call(_ name: String, arguments: JSON) async -> MCPToolResult { MCPToolResult(text: arguments.text) }
}

final class MCPTests: XCTestCase {
    let server = MCPServer(version: "test", instructions: "Use echo.", tools: EchoTools())

    func send(_ text: String, headers: [String: String]? = nil) async -> MCPReply { await server.handle(Data(text.utf8), headers: headers) }

    func testJSONSerialisationKeepsOrderAndEscapes() throws {
        let j: JSON = ["b": 1, "a": "x\"\\\n\u{1}é", "c": [true, .null, 2.5, 3.0], "skip": nil]
        XCTAssertEqual(j.text, #"{"b":1,"a":"x\"\\\n\u0001é","c":[true,null,2.5,3]}"#)
        XCTAssertEqual(JSON.double(.nan).text, "null", "no number is written as null, never 0")
        let back = try JSON.parse(j.data)
        XCTAssertEqual(back, j, "objects compare as maps; parsing restores every value")
        XCTAssertEqual(try JSON.parse(Data("[1, 1.5, true]".utf8)), [1, 1.5, true], "ints, doubles and booleans are told apart")
    }

    func testParseErrorsAndInvalidRequests() async {
        var r = await send("{not json")
        XCTAssertEqual(r.status, 400); XCTAssertEqual(r.body?["error"]?["code"]?.int, -32700); XCTAssertEqual(r.body?["id"], .null)
        r = await send(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        XCTAssertEqual(r.body?["error"]?["code"]?.int, -32600, "batches are refused")
        r = await send(#"{"id":1,"method":"ping"}"#)
        XCTAssertEqual(r.body?["error"]?["code"]?.int, -32600, "jsonrpc 2.0 is required")
        XCTAssertEqual(r.body?["id"]?.int, 1, "the id is echoed when it could be read")
        r = await send(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
        XCTAssertEqual(r.body?["error"]?["code"]?.int, -32600, "a null id is invalid in MCP")
        r = await send(#"{"jsonrpc":"2.0","id":"a","method":"ping","params":[1]}"#)
        XCTAssertEqual(r.body?["error"]?["code"]?.int, -32602)
        r = await send(#"{"jsonrpc":"2.0","id":7,"method":"nope"}"#)
        XCTAssertEqual(r.body?["error"]?["code"]?.int, -32601); XCTAssertEqual(r.status, 200, "legacy: an error in a 200")
    }

    func testNotificationsAndClientResponsesGetNoReply() async {
        var r = await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(r.status, 202); XCTAssertNil(r.body)
        r = await send(#"{"jsonrpc":"2.0","id":3,"result":{}}"#)
        XCTAssertEqual(r.status, 202); XCTAssertNil(r.body)
    }

    func testInitializeNegotiatesALegacyVersion() async throws {
        var r = await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let res = try XCTUnwrap(r.body?["result"])
        XCTAssertEqual(r.body?["id"]?.int, 1)
        XCTAssertEqual(res["protocolVersion"]?.string, "2025-06-18", "a supported legacy version is echoed")
        XCTAssertNotNil(res["capabilities"]?["tools"])
        XCTAssertEqual(res["serverInfo"]?["name"]?.string, "flightdeck")
        XCTAssertEqual(res["instructions"]?.string, "Use echo.")
        XCTAssertNil(res["resultType"], "legacy results keep their legacy shape")
        r = await send(#"{"jsonrpc":"2.0","id":"x","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        XCTAssertEqual(r.body?["result"]?["protocolVersion"]?.string, MCPServer.legacyVersions[0], "unknown: offer the newest legacy version")
        XCTAssertEqual(r.body?["id"]?.string, "x")
    }

    func testToolsListShape() async throws {
        let r = await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap(r.body?["result"]?["tools"]?.array)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"]?.string, "echo")
        XCTAssertEqual(tools[0]["inputSchema"]?["type"]?.string, "object")
        XCTAssertEqual(tools[0]["annotations"]?["readOnlyHint"]?.bool, true)
        XCTAssertEqual(tools[0]["annotations"]?["destructiveHint"]?.bool, false)
    }

    /// The real tool list: every tool has a description and an object schema whose required keys exist.
    func testRealToolSchemas() throws {
        let specs = MCPTools(source: FakeSource()).specs
        XCTAssertEqual(Set(specs.map(\.name)), ["get_status", "list_processes", "get_process", "sample_stacks", "recent_incidents",
                                                "diagnostic_reports", "history", "checkup", "trends", "temperatures", "wifi", "camera_mic",
                                                "restarts", "panics"])
        for s in specs {
            XCTAssertFalse(s.description.isEmpty)
            XCTAssertEqual(s.inputSchema["type"]?.string, "object")
            let props = try XCTUnwrap(s.inputSchema["properties"])
            for r in s.inputSchema["required"]?.array ?? [] { XCTAssertNotNil(props[r.string ?? ""], "\(s.name) requires a declared property") }
        }
    }

    func testModernRequestsAreStatelessWithResultType() async throws {
        let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
        var r = await send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"a":1},"# + meta + "}}",
                           headers: ["mcp-protocol-version": "2026-07-28", "mcp-method": "tools/call", "mcp-name": "echo"])
        let res = try XCTUnwrap(r.body?["result"])
        XCTAssertEqual(res["resultType"]?.string, "complete")
        XCTAssertEqual(res["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"]?.string, "flightdeck")
        XCTAssertEqual(res["content"]?.array?.first?["text"]?.string, #"{"a":1}"#)
        r = await send(#"{"jsonrpc":"2.0","id":2,"method":"server/discover","params":{"# + meta + "}}")
        XCTAssertEqual(r.body?["result"]?["supportedVersions"], .strings(MCPServer.supportedVersions))
        r = await send(#"{"jsonrpc":"2.0","id":3,"method":"nope","params":{"# + meta + "}}")
        XCTAssertEqual(r.status, 404, "modern unknown method is a 404 with a JSON-RPC body")
        XCTAssertEqual(r.body?["error"]?["code"]?.int, -32601)
    }

    func testUnsupportedVersionAndHeaderMismatch() async {
        var r = await send(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01"}}}"#)
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(r.body?["error"]?["code"]?.int, -32022)
        XCTAssertEqual(r.body?["error"]?["data"]?["requested"]?.string, "1900-01-01")
        XCTAssertEqual(r.body?["error"]?["data"]?["supported"]?.array?.count, MCPServer.supportedVersions.count)
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#
        r = await send(ping, headers: ["mcp-protocol-version": "2025-11-25"])
        XCTAssertEqual(r.body?["error"]?["code"]?.int, -32020); XCTAssertEqual(r.status, 400)
        r = await send(ping, headers: ["mcp-method": "tools/list"])
        XCTAssertEqual(r.body?["error"]?["code"]?.int, -32020)
        r = await send(ping, headers: [:])
        XCTAssertNotNil(r.body?["result"], "missing mirror headers are tolerated")
        // Mcp-Name in the base64 sentinel form is decoded before comparing.
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo"}}"#
        r = await send(call, headers: ["mcp-name": "=?base64?" + Data("echo".utf8).base64EncodedString() + "?="])
        XCTAssertNotNil(r.body?["result"])
        r = await send(call, headers: ["mcp-name": "other"])
        XCTAssertEqual(r.body?["error"]?["code"]?.int, -32020)
    }

    func testToolCallErrors() async {
        var r = await send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"missing"}}"#)
        XCTAssertEqual(r.body?["error"]?["code"]?.int, -32602)
        r = await send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":"x"}}"#)
        XCTAssertEqual(r.body?["error"]?["code"]?.int, -32602)
    }

    func testToolTextIsCapped() {
        let long = String(repeating: "é", count: MCPServer.maxToolTextBytes)   // 2 bytes each
        let c = MCPServer.capped(long)
        XCTAssertLessThan(c.utf8.count, MCPServer.maxToolTextBytes + 200)
        XCTAssertTrue(c.contains("[truncated"))
        XCTAssertEqual(MCPServer.capped("short"), "short")
    }
}

/// Guided prompts: listed with their arguments, rendered with them, and refused without required ones.
final class MCPPromptTests: XCTestCase {
    let server = MCPServer(version: "test", instructions: "Use echo.", tools: EchoTools())
    func send(_ text: String) async -> JSON? { await server.handle(Data(text.utf8)).body }

    func testPromptsAreAdvertisedAndListed() async {
        let initReply = await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        XCTAssertNotNil(initReply?["result"]?["capabilities"]?["prompts"])
        let list = await send(#"{"jsonrpc":"2.0","id":2,"method":"prompts/list"}"#)
        guard case .array(let prompts)? = list?["result"]?["prompts"] else { return XCTFail("no prompts array") }
        XCTAssertEqual(prompts.count, MCPPrompts.all.count)
        XCTAssertTrue(prompts.contains { $0["name"]?.string == "diagnose_slow_mac" })
        let app = prompts.first { $0["name"]?.string == "investigate_app" }
        guard case .array(let args)? = app?["arguments"] else { return XCTFail("no arguments") }
        XCTAssertEqual(args.first?["name"]?.string, "app")
    }

    func testPromptRendersArgumentsAndOnlyNamesRealTools() async {
        let r = await send(#"{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{"name":"investigate_app","arguments":{"app":"Safari"}}}"#)
        guard case .array(let msgs)? = r?["result"]?["messages"], let text = msgs.first?["content"]?["text"]?.string else { return XCTFail("no message") }
        XCTAssertEqual(msgs.first?["role"]?.string, "user")
        XCTAssertTrue(text.contains("\"Safari\""))
        // Every tool a prompt mentions must exist, so an assistant following it never calls something unknown.
        let toolNames = ["get_status", "list_processes", "get_process", "sample_stacks", "recent_incidents", "diagnostic_reports", "history", "checkup", "trends", "temperatures", "wifi", "camera_mic"]
        for p in MCPPrompts.all {
            let body = p.render(["app": "X", "minutes": "30", "hours": "3", "days": "7"])
            let mentioned = body.split(whereSeparator: { !$0.isLetter && $0 != "_" }).map(String.init).filter { $0.contains("_") && $0 == $0.lowercased() }
            for m in mentioned where m.hasPrefix("get_") || m.hasPrefix("list_") || m.hasSuffix("_reports") || m.hasSuffix("_stacks") || m.hasSuffix("_incidents") {
                XCTAssertTrue(toolNames.contains(m), "\(p.name) mentions unknown tool \(m)")
            }
        }
    }

    func testMissingRequiredArgumentAndUnknownPrompt() async {
        let missing = await send(#"{"jsonrpc":"2.0","id":4,"method":"prompts/get","params":{"name":"investigate_app","arguments":{"app":"  "}}}"#)
        XCTAssertEqual(missing?["error"]?["code"]?.int, -32602)
        let unknown = await send(#"{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"nope"}}"#)
        XCTAssertEqual(unknown?["error"]?["code"]?.int, -32602)
    }
}
