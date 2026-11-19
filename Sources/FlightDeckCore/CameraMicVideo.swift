import Foundation
import CoreMediaIO
// Camera use from CoreMediaIO, event-driven: a listener on the system's device list (a USB webcam, a display camera
// or a Continuity Camera iPhone appearing or going away) and one on every video device's
// kCMIODevicePropertyDeviceIsRunningSomewhere. Reading these properties never opens a camera, so it needs no camera
// permission and never lights the green dot.
//
// AVCaptureDevice.isInUseByAnotherApplication reports the same per-device flag; it's not used because touching the
// AVFoundation capture stack is what privacy tools should avoid, and CoreMediaIO has the device-list listener anyway.
// Neither says *which* app: CoreMediaIO has no per-process state, so the camera's app comes from macOS's privacy
// indicator (CameraMicIndicatorLog.swift), or stays unknown.

final class VideoDeviceMonitor {
    /// Called on `queue` whenever anything relevant may have changed.
    var onChange: () -> Void = {}
    private let queue: DispatchQueue
    private var listeners: [CMIOObjectID: (CMIOObjectPropertyAddress, CMIOObjectPropertyListenerBlock)] = [:]

    init(queue: DispatchQueue) { self.queue = queue }

    static let system = CMIOObjectID(kCMIOObjectSystemObject)

    func start() { refreshListeners() }

    func stop() {
        for (obj, l) in listeners { var a = l.0; CMIOObjectRemovePropertyListenerBlock(obj, &a, queue, l.1) }
        listeners = [:]
    }

    /// Listens to the device list and each current device; drops listeners of devices that are gone. On `queue`.
    func refreshListeners() {
        let devices = Self.deviceIDs()
        var want: [CMIOObjectID: CMIOObjectPropertySelector] = [Self.system: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)]
        for d in devices { want[d] = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere) }
        for (obj, l) in listeners where want[obj] == nil {
            var a = l.0; CMIOObjectRemovePropertyListenerBlock(obj, &a, queue, l.1)
            listeners[obj] = nil
        }
        for (obj, sel) in want where listeners[obj] == nil {
            var a = Self.address(sel)
            let isList = obj == Self.system
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                if isList { self.refreshListeners() }
                self.onChange()
            }
            if CMIOObjectAddPropertyListenerBlock(obj, &a, queue, block) == noErr { listeners[obj] = (a, block) }
        }
    }

    /// Every video device, and whether each is running for any process.
    func read() -> (running: [SensorDevice], all: [SensorDevice]) {
        var running: [SensorDevice] = [], all: [SensorDevice] = []
        for d in Self.deviceIDs() {
            let dev = SensorDevice(uid: Self.string(d, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) ?? "\(d)",
                                   name: Self.string(d, CMIOObjectPropertySelector(kCMIOObjectPropertyName)) ?? "Camera \(d)",
                                   kind: .camera, transport: AudioInputMonitor.transport(Self.uint(d, CMIOObjectPropertySelector(kCMIODevicePropertyTransportType))))
            all.append(dev)
            if Self.uint(d, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)) == 1 { running.append(dev) }
        }
        return (running.sorted { $0.name < $1.name }, all.sorted { $0.name < $1.name })
    }

    // MARK: CoreMediaIO helpers

    static func address(_ sel: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: sel, mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func deviceIDs() -> [CMIOObjectID] {
        var a = address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)), size: UInt32 = 0, used: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(system, &a, 0, nil, size, &used, &out) == noErr else { return [] }
        return Array(out.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    static func uint(_ obj: CMIOObjectID, _ sel: CMIOObjectPropertySelector) -> UInt32? {
        var a = address(sel), v: UInt32 = 0, used: UInt32 = 0
        return CMIOObjectGetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &v) == noErr ? v : nil
    }

    static func string(_ obj: CMIOObjectID, _ sel: CMIOObjectPropertySelector) -> String? {
        var a = address(sel), used: UInt32 = 0
        var v: Unmanaged<CFString>?
        guard CMIOObjectGetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &v) == noErr,
              let s = v else { return nil }
        return s.takeRetainedValue() as String   // +1 reference, as with CoreAudio
    }
}
