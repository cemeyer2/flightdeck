// Tests for the Connections page's listening-ports parsers (netstat and the lsof fallback), using captured output with
// addresses changed, plus a live check that this Mac's netstat reports socket owners.
import XCTest
@testable import FlightDeckCore

final class ListeningPortsTests: XCTestCase {
    /// Captured from `netstat -anv -p tcp` on macOS 27. Includes a process name with spaces ("Google Chrome He").
    static let tcp = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
    tcp4       0      0  10.0.0.5.58854         10.0.0.40.445          ESTABLISHED   1354116249     29285538 3643920  361144      kernel_task:0      00082 00000008 00000000014c523e 00000082 04104900      3      0 000000
    tcp46      0      0  *.54850                *.*                    LISTEN                 0            0  131072  131072       AssetCache:32143  00100 00000006 00000000014ba93d 00000000 00002800      1      0 000000
    tcp4       0      0  127.0.0.1.65288        *.*                    LISTEN                 0            0  131072  131072      app_inkwell:23689  00100 00000006 0000000000f6a0bc 00000001 00000800      1      0 000000
    tcp6       0      0  ::1.8021               *.*                    LISTEN                 0            0  131072  131072          launchd:1      00180 00000006 0000000000000029 00000000 00000800      1      0 000000
    tcp4       0      0  10.0.0.5.3000          *.*                    LISTEN                 0            0  131072  131072 Google Chrome He:938    00100 00000006 0000000000000029 00000000 00000800      1      0 000000
    """
    static let udp = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
    udp4       0      0  10.0.0.5.58054         142.251.156.120.443                       12242         4955 1048576   29040 Google Chrome He:938    00102 00000000 00000000014c6624 00000000 04200900      1      0 000002
    udp46      0      0  *.5353                 *.*                                       17424         7212  786896    9216 Google Chrome He:938    00100 00000204 0000000001484790 00000000 00000800      1      0 000002
    """

    func testNetstat() throws {
        let t = try XCTUnwrap(ListeningPorts.parseNetstat(Self.tcp))
        XCTAssertEqual(t.count, 4)   // the ESTABLISHED socket is dropped
        let ac = try XCTUnwrap(t.first { $0.pid == 32143 })
        XCTAssertEqual(ac.process, "AssetCache"); XCTAssertEqual(ac.port, 54850); XCTAssertEqual(ac.family, "IPv4+6")
        XCTAssertEqual(ac.exposure, .allInterfaces)
        XCTAssertEqual(t.first { $0.pid == 23689 }?.exposure, .loopback)
        XCTAssertEqual(t.first { $0.pid == 1 }?.address, "::1")
        XCTAssertEqual(t.first { $0.pid == 1 }?.exposure, .loopback)
        let chrome = try XCTUnwrap(t.first { $0.pid == 938 })
        XCTAssertEqual(chrome.process, "Google Chrome He"); XCTAssertEqual(chrome.exposure, .oneInterface)
        let u = try XCTUnwrap(ListeningPorts.parseNetstat(Self.udp))
        XCTAssertEqual(u.count, 1)   // the connected UDP socket is dropped
        XCTAssertEqual(u.first?.port, 5353); XCTAssertEqual(u.first?.proto, "UDP")
    }

    /// Older netstat without a process column must return nil so the caller falls back to lsof.
    func testNetstatWithoutProcessColumn() {
        let old = "Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)     rhiwat shiwat    pid   epid  state    options\ntcp4 0 0 *.22 *.* LISTEN 131072 131072 1 0 00100 00000006"
        XCTAssertNil(ListeningPorts.parseNetstat(old))
    }

    func testLsof() {
        let out = "p100\ncsshd\nf3\nPTCP\nn*:22\nf4\nPTCP\nn[::1]:631\np200\ncmDNS\nf5\nPUDP\nn*:5353\nf6\nPUDP\nn10.0.0.5:5000->10.0.0.9:6000\n"
        let s = ListeningPorts.parseLsof(out)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.first { $0.port == 631 }?.address, "::1")
        XCTAssertEqual(s.first { $0.port == 631 }?.exposure, .loopback)
        XCTAssertEqual(s.first { $0.port == 22 }?.exposure, .allInterfaces)
    }

    /// The real netstat on this Mac should list owners for every process (this is what decides the fallback).
    func testLiveNetstatHasProcessColumn() throws {
        guard let out = Shell.run("/usr/sbin/netstat", ["-anv", "-p", "tcp"]), out.contains("Proto") else { throw XCTSkip("no netstat") }
        guard out.contains("process:pid") else { throw XCTSkip("this macOS's netstat has no process column") }
        XCTAssertNotNil(ListeningPorts.parseNetstat(out))
        XCTAssertEqual(ListeningPorts.scan().coverage, .allProcesses)
    }
}
