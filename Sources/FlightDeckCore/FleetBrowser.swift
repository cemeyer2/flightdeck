import Foundation
import Network
// Fleet, part 9: finding other Macs. An NWBrowser for _flightdeck._tcp, run only while the Fleet page is open (or for
// a few seconds before a background poll); each result carries the instance name and the fleet ID from its TXT record.

public struct FleetAdvert: Sendable, Equatable, Hashable {
    /// The Bonjour instance name (normally the computer name).
    public var name: String
    /// The host's fleet ID (TXT "id"); nil if the record didn't carry one.
    public var id: String?
    public init(name: String, id: String?) { self.name = name; self.id = id }
}

public final class FleetBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "flightdeck.fleet.browse", qos: .utility)
    private var browser: NWBrowser?
    private let onChange: @Sendable ([FleetAdvert]) -> Void

    public init(onChange: @escaping @Sendable ([FleetAdvert]) -> Void) { self.onChange = onChange }

    public func start() {
        queue.async { [self] in
            guard browser == nil else { return }
            let params = NWParameters()
            params.includePeerToPeer = false
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: FleetProtocol.serviceType, domain: "local."), using: params)
            b.browseResultsChangedHandler = { [onChange] results, _ in
                var found: Set<FleetAdvert> = []
                for r in results {
                    guard case let .service(name, _, _, _) = r.endpoint else { continue }
                    var id: String?
                    if case let .bonjour(txt) = r.metadata { id = txt.dictionary["id"] }
                    found.insert(FleetAdvert(name: name, id: id))
                }
                onChange(found.sorted { $0.name < $1.name })
            }
            b.start(queue: queue)
            browser = b
        }
    }

    public func stop() { queue.async { [self] in browser?.cancel(); browser = nil } }
}

/// Fleet findings for the Engine: a paired Mac in trouble ("Studio: memory pressure critical"), set by the viewer's
/// poll and read with every sample. Locked: written on the main actor, read on the sampling queue.
public final class FleetWatch: @unchecked Sendable {
    public static let shared = FleetWatch()
    private let lock = NSLock()
    private var current: [Finding] = []
    public func set(_ f: [Finding]) { lock.lock(); current = f; lock.unlock() }
    public func findings() -> [Finding] { lock.lock(); defer { lock.unlock() }; return current }

    /// One finding per paired Mac whose worst current finding is a warning, keeping its kind and start.
    public static func findings(for hosts: [(name: String, id: String, status: FleetStatus)]) -> [Finding] {
        hosts.compactMap { h in
            guard let w = h.status.worst, w.severity >= Finding.Severity.warning.rawValue else { return nil }
            return Finding(id: "fleet:\(h.id):\(w.kind)", severity: .caution, icon: "macbook.and.iphone", title: "\(h.name): \(w.title)",
                           detail: "Reported by FlightDeck on that Mac.", since: w.since, destination: "Fleet")
        }
    }
}
