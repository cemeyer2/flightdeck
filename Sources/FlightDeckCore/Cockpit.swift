import Foundation
// The customizable cockpit (the Summary page) as plain data: which instruments exist, the sizes they come in, and a
// named layout of them. Kept in FlightDeckCore (no SwiftUI) so the model, its JSON form and the grid packing can be
// unit-tested; the app target maps each kind to a view (Views/CockpitInstruments.swift).

/// One kind of instrument the user can place in the cockpit. The raw value is what's stored in the layout JSON, so a
/// case must never be renamed; a kind that a newer version saved and this one doesn't know is dropped on load
/// (see `CockpitLayout.init(from:)`) instead of failing the whole layout.
///
/// Adding an instrument: append a case, give it one `spec` line, and draw it in the app (a gauge-type kind returns an
/// InstrumentReading from `Engine.reading` or `CockpitFeeds.reading`; anything else gets a case in InstrumentView).
public enum InstrumentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    // What the Summary page showed before it became customizable, in that order.
    case annunciator, findings, cpu, memory, disk, network, energy, thermals, gpu, topProcesses
    // Added with the cockpit.
    case cpuCores, memoryPressure, swap, fans, battery, wifi, stressMap, clock
    // Digests of the 1.5 pages (FlightDeckCore/PageDigests*.swift, drawn by Views/CockpitFeeds*.swift).
    case destinations, restarts, bootTime, batteryHealth, cameraMic

    public var id: String { rawValue }

    /// Everything the catalogue knows about one kind.
    public struct Spec: Sendable {
        /// Name shown in the "Add instrument" palette (and as the panel title for most kinds).
        public var title: String
        /// SF Symbol for the palette.
        public var symbol: String
        /// Where clicking the instrument goes: a navigation request in the app's "Destination[:Performance tab]" form
        /// ("Performance:Energy", "Processes"). nil for instruments with no single detail page (the clock) or whose
        /// rows already navigate individually (the annunciator lights, each finding).
        public var drillDown: String?
        /// Size a newly added instrument gets. The two banner-like kinds read best across the whole row.
        public var defaultSize: InstrumentSize = .small
        /// A single value with a meter and/or a history graph, which Ambient mode can show as one of its big gauges.
        /// The lists and maps (findings, processes, cores, Stress Map) and the clock are not; Ambient has its own clock
        /// and findings ticker.
        public var isGauge = true
    }

    public var spec: Spec {
        switch self {
        case .annunciator: Spec(title: "Annunciator Panel", symbol: "light.beacon.max", defaultSize: .large, isGauge: false)
        case .findings: Spec(title: "Current Findings", symbol: "stethoscope", defaultSize: .large, isGauge: false)
        case .cpu: Spec(title: "CPU", symbol: "cpu", drillDown: "Performance:CPU")
        case .memory: Spec(title: "Memory", symbol: "memorychip", drillDown: "Performance:Memory")
        case .disk: Spec(title: "Disk", symbol: "internaldrive", drillDown: "Performance:Disk")
        case .network: Spec(title: "Network", symbol: "network", drillDown: "Performance:Network")
        case .energy: Spec(title: "Energy", symbol: "bolt.fill", drillDown: "Performance:Energy")
        case .thermals: Spec(title: "Thermals", symbol: "thermometer.medium", drillDown: "Performance:Thermals")
        case .gpu: Spec(title: "GPU", symbol: "cube.transparent", drillDown: "Performance:GPU")
        case .topProcesses: Spec(title: "Top Processes", symbol: "list.number", drillDown: "Processes", isGauge: false)
        case .cpuCores: Spec(title: "CPU Cores", symbol: "square.grid.3x3", drillDown: "Performance:CPU", defaultSize: .medium, isGauge: false)
        case .memoryPressure: Spec(title: "Memory Pressure", symbol: "gauge.with.dots.needle.67percent", drillDown: "Performance:Memory")
        case .swap: Spec(title: "Swap", symbol: "arrow.left.arrow.right", drillDown: "Performance:Memory")
        case .fans: Spec(title: "Fans", symbol: "fanblades", drillDown: "Performance:Thermals")
        case .battery: Spec(title: "Battery & Charge", symbol: "battery.75percent", drillDown: "Performance:Energy")
        case .wifi: Spec(title: "Wi-Fi Signal", symbol: "wifi", drillDown: "Wi-Fi")
        case .stressMap: Spec(title: "Stress Map", symbol: "circle.hexagongrid", drillDown: "Stress Map", defaultSize: .medium, isGauge: false)
        case .clock: Spec(title: "Clock & Uptime", symbol: "clock", isGauge: false)
        case .destinations: Spec(title: "Destinations", symbol: "point.3.connected.trianglepath.dotted", drillDown: "Destinations")
        case .restarts: Spec(title: "Restarts", symbol: "restart.circle", drillDown: "Restarts & Crashes")
        case .bootTime: Spec(title: "Boot Time", symbol: "power", drillDown: "Restarts & Crashes")
        case .batteryHealth: Spec(title: "Battery Health", symbol: "battery.100percent.circle", drillDown: "Performance:Energy")
        case .cameraMic: Spec(title: "Camera & Mic", symbol: "video", drillDown: "Camera & Mic")
        }
    }

    public var title: String { spec.title }
    public var symbol: String { spec.symbol }
    public var drillDown: String? { spec.drillDown }
    public var defaultSize: InstrumentSize { spec.defaultSize }
    public var isGauge: Bool { spec.isGauge }
}

/// How much of a cockpit row an instrument takes: one column, two, or the whole row (see `CockpitGrid.span`).
public enum InstrumentSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case small, medium, large
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    /// One-letter label for the compact size control in edit mode.
    public var letter: String { String(rawValue.prefix(1)).uppercased() }
}

/// One placed instrument. The id is per placement (not per kind), so drag-and-drop and removal address exactly the
/// instrument the user touched.
public struct InstrumentSlot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: InstrumentKind
    public var size: InstrumentSize
    public init(_ kind: InstrumentKind, _ size: InstrumentSize? = nil, id: UUID = UUID()) {
        self.id = id; self.kind = kind; self.size = size ?? kind.defaultSize
    }
}

/// A named arrangement of instruments, in reading order (left to right, top to bottom).
public struct CockpitLayout: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var slots: [InstrumentSlot]
    /// Which built-in preset this layout started from ("default", "thermals", "network", "ambient"), so "Reset to
    /// Default" can restore that preset's instruments. nil for layouts the user created.
    public var preset: String?

    public init(id: UUID = UUID(), name: String, slots: [InstrumentSlot], preset: String? = nil) {
        self.id = id; self.name = name; self.slots = slots; self.preset = preset
    }

    /// The JSON form of a slot before its kind is checked, so unknown kinds can be skipped one by one.
    private struct RawSlot: Decodable { var id: UUID?; var kind: String; var size: String? }
    private enum CodingKeys: String, CodingKey { case id, name, slots, preset }

    /// Lenient decoding: a slot whose kind or size this version doesn't know is dropped or given the kind's default
    /// size, and a missing id or name is filled in, so one odd entry never throws away the user's whole layout.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Layout"
        preset = try? c.decodeIfPresent(String.self, forKey: .preset)
        let raw = (try? c.decode([RawSlot].self, forKey: .slots)) ?? []
        slots = raw.compactMap { r in
            guard let k = InstrumentKind(rawValue: r.kind) else { return nil }
            return InstrumentSlot(k, r.size.flatMap(InstrumentSize.init(rawValue:)), id: r.id ?? UUID())
        }
    }

    /// The instruments of a built-in preset, with fresh ids. nil for an unknown preset name.
    public static func presetSlots(_ preset: String) -> [InstrumentSlot]? {
        switch preset {
        case "default":
            // Exactly the Summary page as it was before the cockpit: annunciator and findings across the top, then one
            // card per subsystem and the top processes, each one column wide.
            return [InstrumentSlot(.annunciator, .large), InstrumentSlot(.findings, .large)]
                + [InstrumentKind.cpu, .memory, .disk, .network, .energy, .thermals, .gpu, .topProcesses].map { InstrumentSlot($0, .small) }
        case "thermals":
            return [InstrumentSlot(.annunciator, .large), InstrumentSlot(.thermals, .medium), InstrumentSlot(.fans, .small),
                    InstrumentSlot(.cpu, .small), InstrumentSlot(.energy, .medium), InstrumentSlot(.gpu, .small),
                    InstrumentSlot(.cpuCores, .large), InstrumentSlot(.findings, .large)]
        case "network":
            return [InstrumentSlot(.annunciator, .large), InstrumentSlot(.network, .medium), InstrumentSlot(.wifi, .small),
                    InstrumentSlot(.disk, .small), InstrumentSlot(.topProcesses, .small), InstrumentSlot(.stressMap, .medium),
                    InstrumentSlot(.findings, .large)]
        case "ambient":
            // The five big gauges Ambient mode shows unless the user picks another layout.
            return [InstrumentKind.cpu, .memory, .thermals, .energy, .network].map { InstrumentSlot($0, .small) }
        default:
            return nil
        }
    }

    /// Built-in presets in picker order, with their display names.
    public static let presets: [(id: String, name: String)] = [("default", "Default"), ("thermals", "Thermals"),
                                                                ("network", "Network"), ("ambient", "Ambient")]

    /// A fresh copy of a built-in preset.
    public static func makePreset(_ preset: String) -> CockpitLayout? {
        guard let slots = presetSlots(preset), let name = presets.first(where: { $0.id == preset })?.name else { return nil }
        return CockpitLayout(name: name, slots: slots, preset: preset)
    }

    // MARK: Editing

    public func contains(_ kind: InstrumentKind) -> Bool { slots.contains { $0.kind == kind } }

    /// Appends an instrument at its default size (or `size`) and returns its id.
    @discardableResult
    public mutating func add(_ kind: InstrumentKind, size: InstrumentSize? = nil) -> UUID {
        let s = InstrumentSlot(kind, size); slots.append(s); return s.id
    }

    public mutating func remove(_ id: UUID) { slots.removeAll { $0.id == id } }

    public mutating func setSize(_ id: UUID, _ size: InstrumentSize) {
        if let i = slots.firstIndex(where: { $0.id == id }) { slots[i].size = size }
    }

    /// Drag-and-drop: moves `id` into the place of `target`. Dragging forward lands after the target and dragging back
    /// lands before it, which is what the user sees as "drop it where that one is". Unknown ids change nothing.
    public mutating func move(_ id: UUID, onto target: UUID) {
        guard id != target, let from = slots.firstIndex(where: { $0.id == id }),
              let to = slots.firstIndex(where: { $0.id == target }) else { return }
        let s = slots.remove(at: from)
        slots.insert(s, at: to)   // after removal, `to` is just past the target when moving forward, at it when moving back
    }

    /// Keyboard/button alternative to dragging: moves one place earlier (-1) or later (+1), clamped to the ends.
    public mutating func move(_ id: UUID, by delta: Int) {
        guard let from = slots.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(from + delta, 0), slots.count - 1)
        guard to != from else { return }
        let s = slots.remove(at: from)
        slots.insert(s, at: to)
    }

    /// Restores the preset this layout came from, keeping its id and name. Layouts the user created reset to the
    /// Default preset's instruments.
    public mutating func reset() {
        slots = Self.presetSlots(preset ?? "default") ?? Self.presetSlots("default") ?? []
    }
}
