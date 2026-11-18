// Demo mode's charging session: an invented MacBook on a 96 W USB-C PD charger at 20 V × 4.7 A, 40 minutes into a
// charge from 18% to 64%. Nothing comes from this Mac. The adapter and telemetry are written as an AppleSmartBattery-
// shaped dictionary and run through the real parser, so the demo exercises the same code as live data.
import Foundation
import FlightDeckCore

@MainActor
enum DemoCharging {
    static func inputs(now: Date = Date()) -> ChargingInputs {
        let start = now.addingTimeInterval(-40 * 60)
        // 18% → 64% over 40 min: about 1.15 %/min, with charge power easing from 58 W to 49 W as the voltage rises.
        let points = (0...80).map { i -> ChargePoint in
            let t = Double(i) / 80
            return ChargePoint(time: start.addingTimeInterval(t * 2400), percent: 18 + 46 * t, batteryW: 58 - 9 * t + sin(Double(i) / 3) * 0.6)
        }
        let details = ChargingDetails.parse(registry)
        let battery = try? JSONDecoder().decode(BatteryInfo.self, from: Data(batteryJSON.utf8))
        return ChargingInputs(battery: battery, details: details, session: ChargeSessionCurve(start: start, points: points),
                              peakSystemW: 41, pmset: nil, condition: "Good", desktopAdapter: nil, now: now)
    }

    /// The invented battery (percent, charging state, capacities, temperature, 12.48 V × 3.92 A ≈ 48.9 W in).
    static let batteryJSON = """
    {"percent": 64, "isCharging": true, "externalConnected": true, "cycleCount": 214, "maxCapacity": 5810,
     "designCapacity": 6249, "temperature": 33.4, "voltage": 12.48, "amperage": 3.92, "timeRemaining": 52, "adapterWatts": 96}
    """

    /// AppleSmartBattery-shaped keys for the invented charger (units as the registry uses: mV, mA, mW, mAh).
    static var registry: [String: Any] {
        [
            "ExternalConnected": true, "IsCharging": true, "FullyCharged": false, "AvgTimeToFull": 52,
            "DesignCycleCount9C": 1000, "DeviceName": "demo-gauge",
            "AdapterDetails": [
                "Watts": 96, "Voltage": 20_000, "Current": 4_700, "AdapterVoltage": 20_000, "Name": "96W USB-C Power Adapter",
                "Manufacturer": "Demo Power Co.", "FamilyCode": NSNumber(value: UInt64(0xFFFF_FFFF_E000_400A)), "IsWireless": false,
                "UsbHvcHvcIndex": 3,
                "UsbHvcMenu": [
                    ["Index": 0, "MaxVoltage": 5_000, "MaxCurrent": 3_000], ["Index": 1, "MaxVoltage": 9_000, "MaxCurrent": 3_000],
                    ["Index": 2, "MaxVoltage": 15_000, "MaxCurrent": 3_000], ["Index": 3, "MaxVoltage": 20_000, "MaxCurrent": 4_700],
                ] as [[String: Int]],
            ] as [String: Any],
            "BatteryData": ["DesignCapacity": 6_249, "NominalChargeCapacity": 5_810, "FullChargeCapacity": 5_702,
                            "CellVoltage": [4_160, 4_158, 4_162]] as [String: Any],
            "PowerTelemetryData": ["SystemPowerIn": 76_400, "SystemLoad": 22_100, "BatteryPower": 48_900, "AdapterEfficiencyLoss": 5_200],
            "ChargerData": ["NotChargingReason": 0, "SlowChargingReason": 0, "TimeChargingThermallyLimited": 0],
            "PortControllerInfo": [
                ["PortControllerActiveContractRdo": 0, "PortControllerNPDOs": 0],
                ["PortControllerActiveContractRdo": 0x4004_B12C, "PortControllerNPDOs": 4],
                ["PortControllerActiveContractRdo": 0, "PortControllerNPDOs": 0],
            ] as [[String: Int]],
        ]
    }
}
