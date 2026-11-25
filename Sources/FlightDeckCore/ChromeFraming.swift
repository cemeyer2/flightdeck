import Foundation
import Darwin
// Chrome tabs: native-messaging framing, a 4-byte length in native byte order followed by that many bytes of JSON. The
// same framing is used on Chrome's stdin/stdout pipe and on the host-to-app socket. Both readers refuse a frame over
// `ChromeTabsConstants.maxFrameBytes` from its length alone, before allocating anything for the body.

public enum ChromeFraming {
    public enum FrameError: Error, Equatable { case tooLarge(UInt32) }

    public static func encode(_ payload: Data) -> Data {
        var out = withUnsafeBytes(of: UInt32(payload.count)) { Data($0) }
        out.append(payload)
        return out
    }

    /// Reads one frame through `readExact`, which returns exactly n bytes or nil at end of input. Returns nil at a clean
    /// end of input (or one cut short inside a frame), and throws `.tooLarge` without asking for the body.
    public static func readFrame(max: Int = ChromeTabsConstants.maxFrameBytes, _ readExact: (Int) -> Data?) throws -> Data? {
        guard let header = readExact(4), header.count == 4 else { return nil }
        let len = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard Int(len) <= max else { throw FrameError.tooLarge(len) }
        if len == 0 { return Data() }
        guard let body = readExact(Int(len)), body.count == Int(len) else { return nil }
        return body
    }

    /// Exactly `count` bytes from `fd`, looping over short reads and retrying on EINTR; nil at EOF or on an error.
    public static func readExact(fd: Int32, count: Int) -> Data? {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
            if n > 0 { got += n } else if n < 0 && errno == EINTR { continue } else { return nil }
        }
        return Data(buf)
    }

    /// Writes one whole frame, looping over short writes. False on any error (e.g. the peer went away).
    public static func writeFrame(fd: Int32, _ payload: Data) -> Bool {
        let frame = encode(payload)
        return frame.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }
}
