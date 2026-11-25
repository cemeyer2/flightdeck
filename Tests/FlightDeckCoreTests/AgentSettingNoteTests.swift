import XCTest
@testable import FlightDeckCore

final class AgentSettingNoteTests: XCTestCase {
    func testReplyShowsItsError() {
        var n = AgentSettingNote()
        let t = n.ticket()
        n.reply("helper unreachable", ticket: t)
        XCTAssertEqual(n.error, "helper unreachable")
        n.reply(nil, ticket: n.ticket())
        XCTAssertNil(n.error)
    }

    /// Lock or a new session while the change was out: its reply must not bring the note back.
    func testReplyAfterInvalidateIsDropped() {
        var n = AgentSettingNote()
        let t = n.ticket()
        n.invalidate()
        n.reply("not authorized", ticket: t)
        XCTAssertNil(n.error)
    }

    func testInvalidateClears() {
        var n = AgentSettingNote()
        n.reply("x", ticket: n.ticket())
        n.invalidate()
        XCTAssertNil(n.error)
    }
}
