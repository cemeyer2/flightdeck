import Foundation
import IOKit
import IOKit.ps

// Power, battery and thermal readings for each snapshot. Battery data comes from the AppleSmartBattery IORegistry node
// (public, no root), the power source from IOPowerSources, temperatures from the private IOHIDEventSystemClient API
// and fans from SMC.swift. PowerSampler is called once per tick on the sampling queue.
/// AppleSmartBattery state. Optional fields are nil when this Mac's battery firmware doesn't publish the key.
public struct BatteryInfo: Codable, Sendable {
    /// Charge in %. On Apple silicon CurrentCapacity/MaxCapacity are already percentages (MaxCapacity 100); on Intel they
    /// are mAh. The ratio works for both.
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
    /// Rated wattage of the connected power adapter, if one is connected and reports it.
    public var adapterWatts: Int?
    /// Full-charge capacity as % of design capacity (the "Maximum Capacity" figure); nil if either is missing.
    public var health: Double? {
        guard let m = maxCapacity, let d = designCapacity, d > 0 else { return nil }
        return Double(m) / Double(d) * 100
    }
}

/// One power/thermal reading. Watts are Measured: unavailable on desktops without a battery or when the firmware
/// doesn't report system load, never 0.
public struct PowerSample: Codable, Sendable {
    public var batteryWatts: Measured<Double>   // + charging, - draining
    public var systemWatts: Measured<Double>
    public var battery: BatteryInfo?
    public var powerSource: String
    public var lowPowerMode: Bool
    public var thermalState: Int      // ProcessInfo.ThermalState rawValue
    /// HID temperature sensors, refreshed only every `sensorInterval` seconds (between reads the last values repeat).
    public var temperatures: [SensorReading]
    /// Highest sensor temperature in °C; unavailable when no sensors could be read.
    public var hottest: Measured<Double>
    /// Fan speeds from the SMC (empty on fanless Macs; nil in traces recorded before fans were read).
    public var fans: [FanReading]? = nil
    /// Charger contract, power telemetry and battery facts (ChargingDetails.swift); nil on Macs without a battery node
    /// and in traces recorded before charging insights existed.
    public var charging: ChargingDetails? = nil
    /// SMC temperature keys with a known meaning on this chip (SensorKeyTables), named by key ("Tp01"); read on the
    /// same cadence as `temperatures`. nil in traces recorded before they were read. SensorCatalog names and groups them.
    public var smcTemperatures: [SensorReading]? = nil
    /// When `temperatures` and `smcTemperatures` were last actually read (between reads the same values repeat), so
    /// per-sensor statistics count each reading once. nil in older traces.
    public var sensorsReadAt: Date? = nil
}

/// One named temperature sensor in °C.
public struct SensorReading: Codable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var celsius: Double
    /// Public so demo mode and tests can describe sensors this Mac may not have.
    public init(name: String, celsius: Double) { self.name = name; self.celsius = celsius }
}

/// Stateful (sensor cache); confined to the sampling queue.
public final class PowerSampler {
    private let thermal = ThermalSensors()
    /// Reading every HID sensor costs ~70 ms, so sensors refresh on their own slower cadence.
    public static let sensorInterval: TimeInterval = 4
    /// No window visible: read the (expensive) temperature sensors every 10 s instead of every 4 s.
    public var background = false
    private var lastSensorRead: Date?
    private var lastTemps: [SensorReading] = []
    private var lastSMCTemps: [SensorReading] = []
    /// The SMC keys worth reading on this chip: only those with a known meaning (about 25 on an M1 Max, ~6 ms).
    private let smcKeys = SensorKeyTables.keys(for: .current)
    public init() {}

    public func sample() -> PowerSample {
        var battery: BatteryInfo?
        var batteryW: Measured<Double> = .unavailable("no battery")
        var systemW: Measured<Double> = .unavailable("not reported by this Mac")
        var charging: ChargingDetails?
        // Desktops have no AppleSmartBattery node, which leaves battery nil and both wattages unavailable.
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
                // Voltage is in mV. Amperage is in mA but published as an unsigned 64-bit two's-complement value, so it is
                // reinterpreted as Int64 to recover the sign (negative = discharging). InstantAmperage is preferred over
                // the averaged
                // Amperage because it tracks load changes within one sample.
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
                    // Temperature is in hundredths of a degree C. TimeRemaining 65535 means "still calculating", reported as nil.
                    temperature: i("Temperature").map { Double($0) / 100 },
                    voltage: volt, amperage: amp,
                    timeRemaining: (tr ?? 65535) < 65535 ? tr : nil,
                    adapterWatts: (d["AdapterDetails"] as? [String: Any]).flatMap { ($0["Watts"] as? NSNumber)?.intValue })
                // Charging insights come from the same dictionary, so this costs no extra registry read.
                charging = ChargingDetails.parse(d)
                // Battery power is V × A, signed like the amperage: positive while charging, negative while draining.
                if let volt, let amp { batteryW = .value(volt * amp) }
                // Whole-system power: Apple silicon laptops publish SystemLoad (mW) in PowerTelemetryData. Without it,
                // while running
                // on battery the system draw equals the battery's discharge power; on AC with no telemetry it stays unavailable.
                if let tel = d["PowerTelemetryData"] as? [String: Any],
                   let sl = (tel["SystemLoad"] as? NSNumber)?.doubleValue, sl > 0 {
                    systemW = .value(sl / 1000)
                } else if let volt, let amp, amp < 0, !(battery?.externalConnected ?? false) {
                    systemW = .value(-volt * amp)
                }
            }
        }
        // IOPSCopyPowerSourcesInfo follows the Copy rule (retained); IOPSGetProvidingPowerSourceType follows the Get rule.
        var source = "Unknown"
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let t = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            source = t == kIOPMACPowerKey ? "AC Power" : t == kIOPMBatteryPowerKey ? "Battery" : t
        }
        if lastSensorRead.map({ Date().timeIntervalSince($0) >= (background ? 10 : Self.sensorInterval) }) ?? true {
            lastTemps = thermal.read(); lastSMCTemps = SMC.shared.temperatures(smcKeys); lastSensorRead = Date()
        }
        let temps = lastTemps
        return PowerSample(batteryWatts: batteryW, systemWatts: systemW, battery: battery, powerSource: source,
                           lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                           thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                           temperatures: temps,
                           hottest: temps.map(\.celsius).max().map { .value($0) } ?? .unavailable("no sensors"),
                           fans: SMC.shared.fans(), charging: charging,
                           smcTemperatures: lastSMCTemps, sensorsReadAt: lastSensorRead)
    }
}

/// Reads temperature sensors via IOHIDEventSystemClient (resolved dynamically; unavailable if symbols missing).
/// IOHIDEventSystemClient and friends are private IOKit SPI (no headers), so they are resolved with dlsym from IOKit
/// and the client is typed as AnyObject (it is a CF type). Every reading degrades to an empty list if a symbol is
/// missing. Not thread-safe; used only by PowerSampler on the sampling queue.
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
        // Usage page 0xff00 (Apple vendor) with usage 5 selects the temperature sensor services.
        _ = setMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        client = c
    }

    /// Matched sensor services and their "Product" names, enumerated once on first read and then reused, since the
    /// per-read cost is dominated by event copies (sensors that appear later are not picked up).
    private var services: [(AnyObject, String)]?

    func read() -> [SensorReading] {
        guard let client, let copyServices, let copyProp, let copyEvent, let getFloat else { return [] }
        if services == nil {
            let list = copyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
            services = list.compactMap { s in (copyProp(s, "Product" as CFString)?.takeRetainedValue() as? String).map { (s, $0) } }
        }
        var byName: [String: Double] = [:]
        for (s, name) in services ?? [] {
            // 15 is kIOHIDEventTypeTemperature; event fields are addressed as (type << 16) | index, so 15 << 16 is the
            // temperature level. Readings outside 0...150 °C are sensor errors/placeholders and dropped. Several services can
            // share a Product name; the hottest one is kept.
            guard let ev = copyEvent(s, 15, 0, 0)?.takeRetainedValue() else { continue }
            let t = getFloat(ev, 15 << 16)
            if t > 0 && t < 150 { byName[name] = max(byName[name] ?? 0, t) }
        }
        return byName.map { SensorReading(name: $0.key, celsius: $0.value) }.sorted { $0.name < $1.name }
    }
}
