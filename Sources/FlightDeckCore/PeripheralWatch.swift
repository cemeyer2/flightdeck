import Foundation
import IOKit
// The live side of Peripherals' link speeds: IOKit matching notifications for USB devices and Thunderbolt routers
// appearing or leaving (no polling). A few seconds after the bus settles it re-reads the links (IORegistry only) and
// raises a finding for each drive linked well below its capability, once per plug-in: the finding's id carries the
// IORegistry entry ID, which is new on every plug-in, and an id is never raised twice. Findings linger `linger`
// seconds, or until the device is unplugged.

public final class PeripheralWatch: @unchecked Sendable {
    public static let shared = PeripheralWatch()
    public static let linger: TimeInterval = 3600

    private let queue = DispatchQueue(label: "flightdeck.peripherals.watch", qos: .utility)
    private let lock = NSLock()
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pending: DispatchWorkItem?
    /// Guarded by `lock`.
    private var raised: Set<String> = []
    private var current: [(Finding, Date)] = []
    private var latest = LinkReport()
    /// Called on the watch's queue after each re-read.
    public var onChange: (@Sendable (LinkReport) -> Void)?

    public init() {}

    /// The last reading (empty before the first).
    public var report: LinkReport { lock.lock(); defer { lock.unlock() }; return latest }

    public func findings(now: Date = Date()) -> [Finding] {
        lock.lock(); defer { lock.unlock() }
        current.removeAll { now.timeIntervalSince($0.1) > Self.linger }
        return current.map(\.0)
    }

    /// Registers the notifications (idempotent) and does a first reading.
    public func start() {
        queue.async { [self] in
            guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
            port = p
            IONotificationPortSetDispatchQueue(p, queue)
            let me = Unmanaged.passUnretained(self).toOpaque()
            let callback: IOServiceMatchingCallback = { ctx, it in
                guard let ctx else { return }
                let w = Unmanaged<PeripheralWatch>.fromOpaque(ctx).takeUnretainedValue()
                w.drain(it); w.scheduleRead()
            }
            for cls in ["IOUSBHostDevice", "IOThunderboltSwitch"] {
                for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                    var it: io_iterator_t = 0
                    if IOServiceAddMatchingNotification(p, type, IOServiceMatching(cls), callback, me, &it) == KERN_SUCCESS {
                        drain(it)   // arms the notification
                        iterators.append(it)
                    }
                }
            }
            scheduleRead(after: 1)
        }
    }

    private func drain(_ it: io_iterator_t) { while case let o = IOIteratorNext(it), o != 0 { IOObjectRelease(o) } }

    /// Debounced: a dock arriving brings a dozen devices in a burst.
    private func scheduleRead(after delay: TimeInterval = 3) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reread() }
        pending = w
        queue.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func reread() {
        let r = LinkSpeedReader.read()
        ingest(r, now: Date())
        onChange?(r)
    }

    /// Records a reading and raises findings for newly seen slow drives. Internal for tests.
    func ingest(_ r: LinkReport, now: Date) {
        let found = USBLinks.findings(r.usb, now: now)
        let present = Set(r.usb.map { "usb-slow:\($0.id)" })
        lock.lock(); defer { lock.unlock() }
        latest = r
        current.removeAll { !present.contains($0.0.id) }   // unplugged
        for f in found where raised.insert(f.id).inserted { current.append((f, now)) }
    }
}
