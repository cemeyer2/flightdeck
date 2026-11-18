// AppleSmartBattery fixtures for the charging-insight tests. `thisMacOnBattery` is a capture of a MacBookPro18,2
// (macOS 27.2) running on battery, taken with `ioreg -rn AppleSmartBattery -a`; the serial number is anonymised and
// IOKit housekeeping keys, the opaque ManufacturerData/FedDetails blobs and per-port debug counters are left out.
// Its port controller 4 still holds the last contract (a 140 W USB-C PD charger), which the parser must ignore while
// unplugged. The charging fixtures follow the key layout Apple silicon and Intel Macs publish while on a charger;
// their values are test inputs, not readings.
import Foundation

enum ChargingFixtures {
    static var thisMacOnBattery: [String: Any] { [
        "AdapterDetails": [
            "FamilyCode": 0
        ] as [String: Any],
        "AdapterInfo": 0,
        "Amperage": -1308,
        "AppleRawAdapterDetails": [] as [Any],
        "AppleRawBatteryVoltage": 12397,
        "AppleRawExternalConnected": false,
        "AtCriticalLevel": false,
        "AvgTimeToEmpty": 289,
        "AvgTimeToFull": 65535,
        "BatteryData": [
            "AbsoluteCapacity": 0, "AppleRawCurrentCapacity": 6918, "AppleRawMaxCapacity": 7231,
            "AvgTimeToEmpty": 289, "BatteryPower": -16215, "CurrentCapacity": 100, "DesignCapacity": 8694,
            "FullChargeCapacity": 7231, "FullyCharged": 1, "MaxCapacity": 100, "NominalChargeCapacity": 7475,
            "RemainingCapacity": 6918, "TrueRemainingCapacity": 0
        ] as [String: Any],
        "BatteryInstalled": true,
        "BatteryInvalidWakeSeconds": 30,
        "BatteryPackCount": 1,
        "BatteryShutdownReason": [
            "ShutDownTimestamp": 0, "ShutDownUpoReboot": 0
        ] as [String: Any],
        "BestAdapterIndex": 0,
        "BootPathUpdated": 1793285192,
        "BootVoltage": 0,
        "ChargerConfiguration": 0,
        "ChargerCount": 1,
        "ChargerData": [
            "IsCharging": 0, "NotChargingReason": 4194433, "PMUConfiguration": 0, "PMUConfigured": 0,
            "SlowChargingReason": 0, "TimeChargingThermallyLimited": 0
        ] as [String: Any],
        "CurrentCapacity": 100,
        "CycleCount": 889,
        "DeadBatteryBootData": [
            "ActivePayloads": 0
        ] as [String: Any],
        "DesignCycleCount9C": 1000,
        "DeviceName": "bq40z651",
        "ExternalChargeCapable": false,
        "ExternalConnected": false,
        "FullPathUpdated": 1795005848,
        "FullyCharged": true,
        "InstantAmperage": -1308,
        "IsCharging": false,
        "Location": 0,
        "MaxCapacity": 100,
        "PortControllerInfo": [[
            "PortControllerActiveContractRdo": 0, "PortControllerMaxPower": 0, "PortControllerNEprPDOs": 0,
            "PortControllerNPDOs": 0, "PortControllerPortPDO": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] as [Any]
        ] as [String: Any], [
            "PortControllerActiveContractRdo": 0, "PortControllerMaxPower": 0, "PortControllerNEprPDOs": 0,
            "PortControllerNPDOs": 0, "PortControllerPortPDO": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] as [Any]
        ] as [String: Any], [
            "PortControllerActiveContractRdo": 0, "PortControllerMaxPower": 0, "PortControllerNEprPDOs": 0,
            "PortControllerNPDOs": 0, "PortControllerPortPDO": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] as [Any]
        ] as [String: Any], [
            "PortControllerActiveContractRdo": 298098984, "PortControllerMaxPower": 0,
            "PortControllerNEprPDOs": 1, "PortControllerNPDOs": 4,
            "PortControllerPortPDO": [142709032, 184617, 307498, 410099, 0, 0, 0, 573939, -768567669, 0, 0, 0, 0] as [Any]
        ] as [String: Any]] as [Any],
        "PostChargeWaitSeconds": 120,
        "PostDischargeWaitSeconds": 120,
        "PowerDistribution": [
            "IPDChargingAllowed": 0, "IPDInputCurrent": 0, "IPDInputPower": 0, "IPDInputVoltage": 5000,
            "IPDRatio": 100, "IPDRatioOverride": 255, "IPDWattageOverride": 30000
        ] as [String: Any],
        "PowerTelemetryData": [
            "AccumSystemEffectiveTotalLoad": 0, "AccumSystemEffectiveTotalLoadCount": 0,
            "AccumulatedAdapterEfficiencyLoss": 672523546133212, "AccumulatedBatteryDischarge": -7133088873,
            "AccumulatedBatteryPower": 7765364875, "AccumulatedSystemEnergyConsumed": 237232774698984,
            "AccumulatedSystemLoad": 21744066602, "AccumulatedSystemPowerIn": 854037968446540,
            "AccumulatedWallEnergyEstimate": 6256352539, "AdapterEfficiencyLoss": 0,
            "AdapterEfficiencyLossAccumulatorCount": 646873, "BatteryDischargeAccumulatorCount": 530029,
            "BatteryPower": -16215, "BatteryPowerAccumulatorCount": 279532, "PowerTelemetryErrorCount": 0,
            "SystemCurrentIn": 0, "SystemEffectiveTotalLoad": 0, "SystemEnergyConsumed": 0, "SystemLoad": 16215,
            "SystemLoadAccumulatorCount": 1620152, "SystemPowerIn": 0, "SystemPowerInAccumulatorCount": 890894,
            "SystemVoltageIn": 0, "WallEnergyEstimate": 0
        ] as [String: Any],
        "Serial": "ANONYMISED0000000",
        "SkipperNEIgnoreAtCritical": false,
        "TimeRemaining": 289,
        "UpdateTime": 1795006208,
        "UserVisiblePathUpdated": 1795006208,
        "Voltage": 12397,
        "built-in": true,
    ] }

    /// `thisMacOnBattery` as IOKit really hands it over: Amperage and BatteryPower as unsigned 64-bit two's complement
    /// (ioreg's text output shows 18446744073709550308 for -1308 mA).
    static var thisMacUnsignedAmperage: [String: Any] {
        var d = thisMacOnBattery
        d["Amperage"] = NSNumber(value: UInt64(18446744073709550308)); d["InstantAmperage"] = NSNumber(value: UInt64(18446744073709550308))
        var t = d["PowerTelemetryData"] as! [String: Any]; t["BatteryPower"] = NSNumber(value: UInt64(18446744073709535401)); d["PowerTelemetryData"] = t
        return d
    }

    /// Apple silicon laptop at 64% on a 96 W USB-C PD charger, contract 20 V × 4.7 A; menu in AdapterDetails.
    /// FamilyCode is USB-C PD (0xE000400A) as the unsigned 64-bit value the registry publishes.
    static var appleSiliconCharging: [String: Any] { [
        "ExternalConnected": true, "IsCharging": true, "FullyCharged": false,
        "CurrentCapacity": 64, "MaxCapacity": 100, "Voltage": 12_480, "Amperage": 3_920, "InstantAmperage": 3_920,
        "AvgTimeToFull": 52, "TimeRemaining": 52, "CycleCount": 214, "DesignCycleCount9C": 1000, "DeviceName": "bq40z651",
        "AdapterDetails": [
            "Watts": 96, "Voltage": 20_000, "Current": 4_700, "AdapterVoltage": 20_000, "Name": "96W USB-C Power Adapter",
            "Manufacturer": "Apple Inc.", "Description": "pd charger", "FamilyCode": NSNumber(value: UInt64(18446744073172697098)),
            "IsWireless": false, "UsbHvcHvcIndex": 3,
            "UsbHvcMenu": [
                ["Index": 0, "MaxVoltage": 5_000, "MaxCurrent": 3_000] as [String: Any],
                ["Index": 1, "MaxVoltage": 9_000, "MaxCurrent": 3_000] as [String: Any],
                ["Index": 2, "MaxVoltage": 15_000, "MaxCurrent": 3_000] as [String: Any],
                ["Index": 3, "MaxVoltage": 20_000, "MaxCurrent": 4_700] as [String: Any],
            ] as [Any],
        ] as [String: Any],
        "BatteryData": ["DesignCapacity": 6_249, "NominalChargeCapacity": 5_810, "FullChargeCapacity": 5_702,
                        "CellVoltage": [4_160, 4_158, 4_162] as [Any]] as [String: Any],
        "ChargerData": ["NotChargingReason": 0, "SlowChargingReason": 0, "TimeChargingThermallyLimited": 0] as [String: Any],
        "PowerTelemetryData": ["SystemPowerIn": 76_400, "SystemLoad": 22_100, "BatteryPower": 48_900, "AdapterEfficiencyLoss": 5_200,
                               "SystemVoltageIn": 20_000, "SystemCurrentIn": 3_820] as [String: Any],
        // Port controller 2 of 3 holds the contract; its RDO (object position 4 in bits 31:28) requests the 20 V PDO.
        "PortControllerInfo": [
            ["PortControllerActiveContractRdo": 0, "PortControllerNPDOs": 0, "PortControllerPortPDO": [0, 0] as [Any]] as [String: Any],
            ["PortControllerActiveContractRdo": 0x4004_B12C, "PortControllerNPDOs": 4,
             "PortControllerPortPDO": [142709032, 184617, 307498, 410099] as [Any]] as [String: Any],
            ["PortControllerActiveContractRdo": 0, "PortControllerNPDOs": 0, "PortControllerPortPDO": [0, 0] as [Any]] as [String: Any],
        ] as [Any],
    ] }

    /// Intel-era layout: menu at the top level, no telemetry, packed ManufactureDate, adapter details without a menu.
    static var intelCharging: [String: Any] { [
        "ExternalConnected": true, "IsCharging": true, "CurrentCapacity": 4_100, "MaxCapacity": 5_000,
        "Voltage": 12_100, "Amperage": 2_500, "AvgTimeToFull": 65535, "TimeRemaining": 65535,
        "ManufactureDate": 20_559,   // (2020 - 1980) << 9 | 2 << 5 | 15 = 2020-02-15
        "AdapterDetails": ["Watts": 61, "Current": 3_050, "Voltage": 20_000, "FamilyCode": NSNumber(value: UInt64(18446744073172697098))] as [String: Any],
        "UsbHvcHvcIndex": 2,
        "UsbHvcMenu": [["Index": 0, "MaxVoltage": 5_000, "MaxCurrent": 3_000] as [String: Any],
                       ["Index": 1, "MaxVoltage": 9_000, "MaxCurrent": 3_000] as [String: Any],
                       ["Index": 2, "MaxVoltage": 20_000, "MaxCurrent": 3_050] as [String: Any]] as [Any],
    ] }
}
