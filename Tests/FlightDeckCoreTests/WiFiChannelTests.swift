import XCTest
@testable import FlightDeckCore

/// Channel ↔ frequency, block alignment for every width (including 6 GHz 160/320 MHz), and the beacon IE parser.
final class WiFiChannelTests: XCTestCase {
    func testFrequencies() {
        XCTAssertEqual(WiFiBand.ghz2.frequency(channel: 1), 2412)
        XCTAssertEqual(WiFiBand.ghz2.frequency(channel: 6), 2437)
        XCTAssertEqual(WiFiBand.ghz2.frequency(channel: 14), 2484)
        XCTAssertNil(WiFiBand.ghz2.frequency(channel: 15))
        XCTAssertEqual(WiFiBand.ghz5.frequency(channel: 36), 5180)
        XCTAssertEqual(WiFiBand.ghz5.frequency(channel: 165), 5825)
        XCTAssertEqual(WiFiBand.ghz6.frequency(channel: 1), 5955)
        XCTAssertEqual(WiFiBand.ghz6.frequency(channel: 233), 7115)
        XCTAssertEqual(WiFiBand.ghz6.frequency(channel: 2), 5935)
        XCTAssertNil(WiFiBand.ghz6.frequency(channel: 3), "6 GHz primaries are 4k+1")
        XCTAssertEqual(WiFiBand.ghz6.channels.count, 59)
        XCTAssertEqual(WiFiBand.of(frequency: 2437), .ghz2)
        XCTAssertEqual(WiFiBand.of(frequency: 5180), .ghz5)
        XCTAssertEqual(WiFiBand.of(frequency: 5955), .ghz6)
        XCTAssertEqual(WiFiBand(label: "2.4 GHz"), .ghz2)
        XCTAssertEqual(WiFiBand(label: "6 GHz"), .ghz6)
        XCTAssertNil(WiFiBand(label: "?"))
        XCTAssertEqual(WiFiChannels.widthMHz("80 MHz"), 80)
    }

    func testCenterChannels5GHz() {
        let c = { (p: Int, w: Int) in WiFiChannels.centerChannel(band: .ghz5, primary: p, width: w) }
        XCTAssertEqual(c(36, 20), 36)
        XCTAssertEqual(c(36, 40), 38); XCTAssertEqual(c(40, 40), 38); XCTAssertEqual(c(153, 40), 151); XCTAssertEqual(c(157, 40), 159)
        XCTAssertEqual(c(36, 80), 42); XCTAssertEqual(c(48, 80), 42); XCTAssertEqual(c(52, 80), 58)
        XCTAssertEqual(c(100, 80), 106); XCTAssertEqual(c(132, 80), 138); XCTAssertEqual(c(149, 80), 155); XCTAssertEqual(c(161, 80), 155)
        XCTAssertEqual(c(36, 160), 50); XCTAssertEqual(c(64, 160), 50); XCTAssertEqual(c(100, 160), 114); XCTAssertEqual(c(149, 160), 163)
        XCTAssertNil(c(36, 320), "no 320 MHz on 5 GHz")
    }

    func testCenterChannels6GHz() {
        let c = { (p: Int, w: Int) in WiFiChannels.centerChannel(band: .ghz6, primary: p, width: w) }
        XCTAssertEqual(c(1, 40), 3); XCTAssertEqual(c(5, 40), 3)
        XCTAssertEqual(c(1, 80), 7); XCTAssertEqual(c(37, 80), 39)
        XCTAssertEqual(c(1, 160), 15); XCTAssertEqual(c(37, 160), 47); XCTAssertEqual(c(221, 160), 207)
        XCTAssertEqual(c(1, 320), 31); XCTAssertEqual(c(61, 320), 31); XCTAssertEqual(c(65, 320), 95); XCTAssertEqual(c(129, 320), 159)
        XCTAssertNil(c(193, 320), "the last 320-1 block would run past channel 233")
    }

    func testCenterChannels24GHz() {
        XCTAssertEqual(WiFiChannels.centerChannel(band: .ghz2, primary: 1, width: 40), 3)
        XCTAssertEqual(WiFiChannels.centerChannel(band: .ghz2, primary: 11, width: 40), 9)
        XCTAssertEqual(WiFiChannels.centerChannel(band: .ghz2, primary: 6, width: 40, secondaryAbove: false), 4)
        XCTAssertNil(WiFiChannels.centerChannel(band: .ghz2, primary: 6, width: 80))
    }

    func testSpans() throws {
        // 2.4 GHz 20 MHz is ~22 MHz wide, so 1 and 6 don't touch but 1 and 4 do.
        let s1 = try XCTUnwrap(WiFiChannels.span(band: .ghz2, primary: 1, width: 20))
        let s4 = try XCTUnwrap(WiFiChannels.span(band: .ghz2, primary: 4, width: 20))
        let s6 = try XCTUnwrap(WiFiChannels.span(band: .ghz2, primary: 6, width: 20))
        XCTAssertEqual(WiFiChannels.overlap(s1, s6), 0)
        XCTAssertGreaterThan(WiFiChannels.overlap(s1, s4), 0)
        // 80 MHz on 36 covers 5170–5250 and its four 20 MHz channels.
        let s80 = try XCTUnwrap(WiFiChannels.span(band: .ghz5, primary: 36, width: 80))
        XCTAssertEqual(s80, 5170...5250)
        XCTAssertEqual(WiFiChannels.members(band: .ghz5, span: s80), [36, 40, 44, 48])
        let s160 = try XCTUnwrap(WiFiChannels.span(band: .ghz6, primary: 37, width: 160))
        XCTAssertEqual(WiFiChannels.members(band: .ghz6, span: s160), [33, 37, 41, 45, 49, 53, 57, 61])
        let s320 = try XCTUnwrap(WiFiChannels.span(band: .ghz6, primary: 5, width: 320))
        XCTAssertEqual(WiFiChannels.members(band: .ghz6, span: s320).count, 16)
        // A given centre (from the beacon) wins: 320-2 centred on 63 covers 33–93.
        let s320b = try XCTUnwrap(WiFiChannels.span(band: .ghz6, primary: 37, width: 320, center: 63))
        XCTAssertEqual(WiFiChannels.members(band: .ghz6, span: s320b).first, 33)
        XCTAssertTrue(WiFiChannels.isDFS(.ghz5, 100)); XCTAssertFalse(WiFiChannels.isDFS(.ghz5, 149))
    }

    func testBeaconIEs() {
        // HT operation: primary 6, secondary below, 40 MHz allowed.
        let ht: [UInt8] = [61, 22, 6, 0x07] + Array(repeating: 0, count: 20)
        XCTAssertEqual(WiFiIE.parse(Data(ht), primary: 6), WiFiBeaconInfo(widthMHz: 40, centerChannel: 4, secondaryAbove: false, standard: "802.11n"))
        // HT (40 above) then VHT 80 MHz centred on 42.
        let vht: [UInt8] = [61, 22, 36, 0x05] + Array(repeating: 0, count: 20) + [192, 5, 1, 42, 0, 0, 0]
        let v = WiFiIE.parse(Data(vht), primary: 36)
        XCTAssertEqual(v.widthMHz, 80); XCTAssertEqual(v.centerChannel, 42); XCTAssertEqual(v.standard, "802.11ac")
        // VHT 160 signalled the modern way: CCFS0 = 80 MHz segment, CCFS1 = 160 MHz centre.
        let v160 = WiFiIE.parse(Data([192, 5, 1, 42, 50, 0, 0]), primary: 36)
        XCTAssertEqual(v160.widthMHz, 160); XCTAssertEqual(v160.centerChannel, 50)
        // HE operation with 6 GHz info (params bit 17), 160 MHz: primary 37, CCFS0 39, CCFS1 47.
        let he: [UInt8] = [255, 12, 36, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 37, 0x03, 39, 47, 0]
        let h = WiFiIE.parse(Data(he), primary: 37)
        XCTAssertEqual(h.widthMHz, 160); XCTAssertEqual(h.centerChannel, 47); XCTAssertEqual(h.standard, "802.11ax")
        // EHT operation (ext 106) with info present: 320 MHz, CCFS1 63; it beats the HE element's 160.
        let eht: [UInt8] = [255, 9, 106, 0x01, 0, 0, 0, 0, 0x04, 55, 63]
        let e = WiFiIE.parse(Data(he + eht), primary: 37)
        XCTAssertEqual(e.widthMHz, 320); XCTAssertEqual(e.centerChannel, 63); XCTAssertEqual(e.standard, "802.11be")
        // Truncated and empty input are harmless.
        XCTAssertEqual(WiFiIE.parse(Data([192, 9, 1]), primary: 36), WiFiBeaconInfo())
        XCTAssertEqual(WiFiIE.parse(nil, primary: nil), WiFiBeaconInfo())
    }

    func testNetworkSpanUsesBeaconCenter() throws {
        let n = WiFiNetwork(id: 0, rssi: -60, band: .ghz6, channel: 37, widthMHz: 320, centerChannel: 63)
        XCTAssertEqual(try XCTUnwrap(n.span).lowerBound, Double(5950 + 5 * 63) - 160)
    }
}
