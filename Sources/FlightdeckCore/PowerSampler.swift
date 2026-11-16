import Foundation
import IOKit
import IOKit.ps

public struct BatteryInfo: Codable, Sendable {
    public var percent: Double
    public var isCharging: Bool
    public var externalConnected: Bool
    public var cycleCount: Int?
    public var maxCapacity: Int?      // mAh
    public var designCapacity: Int?   // mAh
    public var temperature: Double?   // C
    public var voltage: Double?       // V
    public var amperage: Double?      // A (negative = discharging)
    public var timeRemaining: Int?    // minutes
    public var adapterWatts: Int?
    public var health: Double? {
        guard let m = maxCapacity, let d = designCapacity, d > 0 else { return nil }
        return Double(m) / Double(d) * 100
    }
}

public struct PowerSample: Codable, Sendable {
    public var batteryWatts: Measured<Double>   // + charging, - draining
    public var systemWatts: Measured<Double>
    public var battery: BatteryInfo?
    public var powerSource: String
    public var lowPowerMode: Bool
    public var thermalState: Int      // ProcessInfo.ThermalState rawValue
    public var temperatures: [SensorReading]
    public var hottest: Measured<Double>
}

public struct SensorReading: Codable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var celsius: Double
}

public final class PowerSampler {
    private let thermal = ThermalSensors()
    /// Reading every HID sensor costs ~70 ms, so sensors refresh on their own slower cadence.
    public static let sensorInterval: TimeInterval = 4
    private var lastSensorRead: Date?
    private var lastTemps: [SensorReading] = []
    public init() {}

    public func sample() -> PowerSample {
        var battery: BatteryInfo?
        var batteryW: Measured<Double> = .unavailable("no battery")
        var systemW: Measured<Double> = .unavailable("not reported by this Mac")
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if svc != 0 {
            defer { IOObjectRelease(svc) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any] {
                // Newer Macs keep capacities inside "BatteryData"; look there too.
                let bd = d["BatteryData"] as? [String: Any] ?? [:]
                func i(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue ?? (bd[k] as? NSNumber)?.intValue }
                let cur = i("CurrentCapacity") ?? 0, mx = i("MaxCapacity") ?? 100
                let volt = i("Voltage").map { Double($0) / 1000 }
                let amp = (d["InstantAmperage"] as? NSNumber ?? d["Amperage"] as? NSNumber).map { Double(Int64(truncatingIfNeeded: $0.int64Value)) / 1000 }
                let tr = i("TimeRemaining")
                battery = BatteryInfo(
                    percent: mx > 0 ? Double(cur) / Double(mx) * 100 : 0,
                    isCharging: (d["IsCharging"] as? Bool) ?? false,
                    externalConnected: (d["ExternalConnected"] as? Bool) ?? false,
                    cycleCount: i("CycleCount"),
                    // NominalChargeCapacity matches the "Maximum Capacity" macOS shows in Battery settings
                    maxCapacity: i("NominalChargeCapacity") ?? i("AppleRawMaxCapacity"),
                    designCapacity: i("DesignCapacity"),
                    temperature: i("Temperature").map { Double($0) / 100 },
                    voltage: volt, amperage: amp,
                    timeRemaining: (tr ?? 65535) < 65535 ? tr : nil,
                    adapterWatts: (d["AdapterDetails"] as? [String: Any]).flatMap { ($0["Watts"] as? NSNumber)?.intValue })
                if let volt, let amp { batteryW = .value(volt * amp) }
                if let tel = d["PowerTelemetryData"] as? [String: Any],
                   let sl = (tel["SystemLoad"] as? NSNumber)?.doubleValue, sl > 0 {
                    systemW = .value(sl / 1000)
                } else if let volt, let amp, amp < 0, !(battery?.externalConnected ?? false) {
                    systemW = .value(-volt * amp)
                }
            }
        }
        var source = "Unknown"
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let t = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            source = t == kIOPMACPowerKey ? "AC Power" : t == kIOPMBatteryPowerKey ? "Battery" : t
        }
        if lastSensorRead.map({ Date().timeIntervalSince($0) >= Self.sensorInterval }) ?? true {
            lastTemps = thermal.read(); lastSensorRead = Date()
        }
        let temps = lastTemps
        return PowerSample(batteryWatts: batteryW, systemWatts: systemW, battery: battery, powerSource: source,
                           lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                           thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                           temperatures: temps,
                           hottest: temps.map(\.celsius).max().map { .value($0) } ?? .unavailable("no sensors"))
    }
}

/// Reads temperature sensors via IOHIDEventSystemClient (resolved dynamically; unavailable if symbols missing).
final class ThermalSensors {
    typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    typealias CopyPropFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private var client: AnyObject?
    private var copyServices: CopyServicesFn?
    private var copyProp: CopyPropFn?
    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self) else { return }
        copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self)
        copyProp = sym("IOHIDServiceClientCopyProperty", CopyPropFn.self)
        copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self)
        getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self)
        guard let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        _ = setMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        client = c
    }

    private var services: [(AnyObject, String)]?

    func read() -> [SensorReading] {
        guard let client, let copyServices, let copyProp, let copyEvent, let getFloat else { return [] }
        if services == nil {
            let list = copyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
            services = list.compactMap { s in (copyProp(s, "Product" as CFString)?.takeRetainedValue() as? String).map { (s, $0) } }
        }
        var byName: [String: Double] = [:]
        for (s, name) in services ?? [] {
            guard let ev = copyEvent(s, 15, 0, 0)?.takeRetainedValue() else { continue }
            let t = getFloat(ev, 15 << 16)
            if t > 0 && t < 150 { byName[name] = max(byName[name] ?? 0, t) }
        }
        return byName.map { SensorReading(name: $0.key, celsius: $0.value) }.sorted { $0.name < $1.name }
    }
}
