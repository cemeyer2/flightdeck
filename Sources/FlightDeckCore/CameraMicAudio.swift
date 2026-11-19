import Foundation
import CoreAudio
// Microphone use from CoreAudio, event-driven: property listeners only, no polling. Listened to:
//   • the system object's device list and process-object list (devices plugged in or removed, e.g. AirPods or a USB
//     headset; audio clients coming and going);
//   • every input-capable device's kAudioDevicePropertyDeviceIsRunningSomewhere;
//   • every process object's kAudioProcessPropertyIsRunningInput and input-device list (macOS 14.2+).
// Any of these just tells CameraMicWatch to re-read; `read()` then works out what's in use.
//
// Why per-process input state matters: "running somewhere" is per device, not per direction, so AirPods or a USB
// headset playing music report "running" with the microphone untouched. And a process can be "running input" from a
// process tap (system-audio capture, e.g. Rogue Amoeba's ARK) with no input device at all. So a microphone counts as in
// use only when a process is reading it (directly, or through an aggregate device that contains it); a running
// input-only device with no visible reader also counts (the reader is then unknown). Without process objects (before
// macOS 14.2) any running input-capable device counts, which can include playback on a headset.

final class AudioInputMonitor {
    /// Called on `queue` whenever anything relevant may have changed.
    var onChange: () -> Void = {}
    private let queue: DispatchQueue
    /// Registered listeners by "object/selector/scope", so re-registration after a device change is idempotent and
    /// removal uses the same block object (CoreAudio matches blocks by identity).
    private var listeners: [String: (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = [:]

    init(queue: DispatchQueue) { self.queue = queue }

    static let system = AudioObjectID(kAudioObjectSystemObject)

    // MARK: Listening

    func start() { refreshListeners() }

    func stop() {
        for (_, l) in listeners { var a = l.1; AudioObjectRemovePropertyListenerBlock(l.0, &a, queue, l.2) }
        listeners = [:]
    }

    /// Listens to the current devices and processes and stops listening to ones that are gone. Called at start and
    /// whenever the device or process list changes. On `queue`.
    func refreshListeners() {
        var want: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (Self.system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal),
        ]
        if Self.hasProcessObjects { want.append((Self.system, kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal)) }
        for d in Self.ids(Self.system, kAudioHardwarePropertyDevices) where Self.streamCount(d, kAudioObjectPropertyScopeInput) > 0 {
            want.append((d, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal))
        }
        for p in Self.processObjects() {
            want.append((p, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal))
            want.append((p, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput))
        }
        let keys = Set(want.map { "\($0.0)/\($0.1)/\($0.2)" })
        for (k, l) in listeners where !keys.contains(k) {
            var a = l.1; AudioObjectRemovePropertyListenerBlock(l.0, &a, queue, l.2)   // fails harmlessly if the object is gone
            listeners[k] = nil
        }
        for (obj, sel, scope) in want {
            let k = "\(obj)/\(sel)/\(scope)"
            guard listeners[k] == nil else { continue }
            var a = Self.address(sel, scope)
            let isList = sel == kAudioHardwarePropertyDevices || sel == kAudioHardwarePropertyProcessObjectList
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                if isList { self.refreshListeners() }   // new devices or processes need their own listeners
                self.onChange()
            }
            if AudioObjectAddPropertyListenerBlock(obj, &a, queue, block) == noErr { listeners[k] = (obj, a, block) }
        }
    }

    // MARK: Reading

    struct Reading {
        var running: [SensorDevice] = []
        var clients: [AudioInputClient] = []
        /// Per-process input state was available (macOS 14.2+).
        var perProcess = false
    }

    /// What's using a microphone now. Cheap (a few dozen property reads), and only run after a listener fired.
    func read() -> Reading {
        var r = Reading()
        // Input-capable devices, and whether each also has outputs (then "running" alone is ambiguous).
        var inputs: [AudioObjectID: (SensorDevice, hasOutput: Bool)] = [:]
        for d in Self.ids(Self.system, kAudioHardwarePropertyDevices) where Self.streamCount(d, kAudioObjectPropertyScopeInput) > 0 {
            let dev = SensorDevice(uid: Self.string(d, kAudioDevicePropertyDeviceUID) ?? "\(d)", name: Self.string(d, kAudioObjectPropertyName) ?? "Audio input \(d)",
                                   kind: .microphone, transport: Self.transport(Self.uint(d, kAudioDevicePropertyTransportType)))
            inputs[d] = (dev, Self.streamCount(d, kAudioObjectPropertyScopeOutput) > 0)
        }
        var read = Set<AudioObjectID>()
        r.perProcess = Self.hasProcessObjects
        if r.perProcess {
            for p in Self.processObjects() where Self.uint(p, kAudioProcessPropertyIsRunningInput) == 1 {
                // Map the process's input devices to real inputs; an aggregate counts through its sub-devices. A
                // process with no real input device here (a process tap) isn't using a microphone.
                var devs: [AudioObjectID] = []
                for d in Self.ids(p, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput) {
                    if inputs[d] != nil { devs.append(d) }
                    else { devs += Self.ids(d, kAudioAggregateDevicePropertyActiveSubDeviceList).filter { inputs[$0] != nil } }
                }
                guard !devs.isEmpty else { continue }
                read.formUnion(devs)
                let pid = Self.uint(p, kAudioProcessPropertyPID).map { pid_t(bitPattern: $0) } ?? -1
                let bundle = Self.string(p, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
                r.clients.append(AudioInputClient(pid: pid, bundleID: bundle, devices: devs.compactMap { inputs[$0]?.0.label }.sorted()))
            }
        }
        for (d, info) in inputs {
            let running = Self.uint(d, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
            // Read by a process; or running and input-only, so it can't be playback; or no per-process state to ask.
            if read.contains(d) || (running && (!info.hasOutput || !r.perProcess)) { r.running.append(info.0) }
        }
        r.running.sort { $0.name < $1.name }
        return r
    }

    // MARK: CoreAudio helpers

    static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static var hasProcessObjects: Bool {
        var a = address(kAudioHardwarePropertyProcessObjectList); return AudioObjectHasProperty(system, &a)
    }
    static func processObjects() -> [AudioObjectID] { hasProcessObjects ? ids(system, kAudioHardwarePropertyProcessObjectList) : [] }

    static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(sel, scope), size: UInt32 = 0
        guard AudioObjectHasProperty(obj, &a), AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return [] }
        return Array(out.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
    /// A 32-bit property (flags, transport codes, and pid_t, which is also 32 bits).
    static func uint(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
        var a = address(sel), v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = address(sel), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var v: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr, let s = v else { return nil }
        return s.takeRetainedValue() as String   // CoreAudio returns a +1 reference for CFString properties
    }
    static func streamCount(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreams, scope), size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(d, &a, 0, nil, &size) == noErr ? Int(size) / MemoryLayout<AudioStreamID>.size : 0
    }

    /// CoreAudio and CoreMediaIO share the transport-type four-character codes.
    static func transport(_ t: UInt32?) -> String? {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: "Built-in"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeVirtual: "Virtual"
        case kAudioDeviceTransportTypeAggregate: "Aggregate"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: "Display"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: "Continuity"
        default: nil
        }
    }
}
