import Foundation
// USB Power Delivery decoding for the port controllers AppleSmartBattery lists in PortControllerInfo (Apple silicon).
// Each controller publishes the charger's source capabilities as raw 32-bit PDOs (PortControllerPortPDO, positions 1-7
// standard range, 8-13 extended/EPR range) and the request it made as an RDO (PortControllerActiveContractRdo). The bit
// layouts are the USB PD 3.1 specification's. Values are kept from the last contract after unplugging, so callers
// only use them while external power is connected.

extension ChargingDetails {
    /// The port controller with a live contract: its index, decoded offers and the RDO's object position (1-based).
    /// nil when no controller, or more than one, has a contract (then which one powers the Mac isn't knowable).
    public static func portContract(_ ports: [[String: Any]]) -> (port: Int, offers: [PDOffer], position: Int?)? {
        let live = ports.enumerated().filter { _, p in (ASB.signed(p["PortControllerActiveContractRdo"]) ?? 0) != 0 && (ASB.int(p["PortControllerNPDOs"]) ?? 0) > 0 }
        guard live.count == 1, let (i, p) = live.first else { return nil }
        let raw = (p["PortControllerPortPDO"] as? [Any] ?? []).map { ASB.signed($0).map { UInt32(truncatingIfNeeded: $0) } ?? 0 }
        let offers = raw.enumerated().compactMap { k, v in decodePDO(v, position: k + 1) }
        let rdo = UInt32(truncatingIfNeeded: ASB.signed(p["PortControllerActiveContractRdo"]) ?? 0)
        let pos = Int((rdo >> 28) & 0xF)
        return (i, offers, pos > 0 ? pos : nil)
    }

    /// Decodes one source PDO; 0 (empty slot), battery and variable supplies give nil.
    /// Fixed (bits 31:30 = 00): voltage bits 19:10 × 50 mV, max current bits 9:0 × 10 mA.
    /// Augmented (11): bits 29:28 = 00 SPR PPS (max V 24:17 × 100 mV, min V 15:8 × 100 mV, current 6:0 × 50 mA),
    /// 01 EPR AVS (max V 25:17 × 100 mV, min V 15:8 × 100 mV, PDP 7:0 in W).
    public static func decodePDO(_ v: UInt32, position: Int) -> PDOffer? {
        guard v != 0 else { return nil }
        switch v >> 30 {
        case 0b00:
            let volts = Double((v >> 10) & 0x3FF) * 0.05, amps = Double(v & 0x3FF) * 0.01
            return volts > 0 ? PDOffer(index: position, kind: .fixed, volts: volts, amps: amps) : nil
        case 0b11:
            let minV = Double((v >> 8) & 0xFF) * 0.1
            switch (v >> 28) & 0b11 {
            case 0b00:
                return PDOffer(index: position, kind: .pps, volts: Double((v >> 17) & 0xFF) * 0.1, minVolts: minV, amps: Double(v & 0x7F) * 0.05)
            case 0b01:
                return PDOffer(index: position, kind: .avs, volts: Double((v >> 17) & 0x1FF) * 0.1, minVolts: minV, amps: nil, pdpWatts: Double(v & 0xFF))
            default: return nil
            }
        default: return nil
        }
    }
}
