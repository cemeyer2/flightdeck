import Foundation

/// What a request reads, which decides what unlock it needs. control = hello/status/lock/remove (no unlock);
/// counters = other processes' usage and system-wide inventories (any live unlock for the uid); contents = another
/// process's arguments, environment, files and stacks (only the unlocking connection itself).
public enum DataTier: Sendable { case control, counters, contents }

public extension HelperRequest {
    var tier: DataTier {
        switch self {
        case .hello, .status, .lock, .removeRightAndSettings: return .control
        case .processRusage, .listeningSockets, .internetSockets, .snapshotSizes, .deviceProfiles, .backgroundItems:
            return .counters
        // Changing the agent setting needs the holder's own authorization, like reading contents.
        case .processDetails, .sampleStacks, .memoryFootprint, .setAgentContents: return .contents
        }
    }

    /// The case name, used for the one-in-flight-per-kind and rate limits.
    var kind: String {
        switch self {
        case .hello: return "hello"
        case .status: return "status"
        case .lock: return "lock"
        case .removeRightAndSettings: return "removeRightAndSettings"
        case .setAgentContents: return "setAgentContents"
        case .processRusage: return "processRusage"
        case .processDetails: return "processDetails"
        case .listeningSockets: return "listeningSockets"
        case .internetSockets: return "internetSockets"
        case .snapshotSizes: return "snapshotSizes"
        case .deviceProfiles: return "deviceProfiles"
        case .backgroundItems: return "backgroundItems"
        case .sampleStacks: return "sampleStacks"
        case .memoryFootprint: return "memoryFootprint"
        }
    }
}

public enum HelperLimits {
    /// Identities per processRusage request; the app splits larger sets.
    public static let maxBatch = 4096
    /// Tool stdout beyond this is refused as "output too large", never silently truncated.
    public static let maxOutputBytes = 8 * 1_048_576
    public static let sampleSeconds = 1...5
    public static let toolTimeout: TimeInterval = 20
    /// Kinds that start a tool (lsof, sample, footprint) or walk another process; an agent can't flood these.
    public static let rateLimitedKinds: Set<String> = ["sampleStacks", "memoryFootprint", "listeningSockets", "internetSockets", "processDetails"]
    public static let minInterval: TimeInterval = 2       // per rate-limited kind
    /// A verified authorization is trusted for this long per connection, so the per-tick rusage call doesn't pay
    /// for an authd round-trip each time. Dropped on lock.
    public static let authCacheTTL: TimeInterval = 0.5
}

public enum HelperValidation {
    /// Never sampled or footprinted: pausing any of these visibly freezes the Mac (or its sound).
    public static let criticalProcessNames: Set<String> = ["WindowServer", "launchd", "kernel_task", "coreaudiod", "loginwindow"]

    /// nil = valid. Checks only the request's own fields; identities and names are checked against the live
    /// process by the helper.
    public static func validate(_ r: HelperRequest) -> HelperRefusal? {
        switch r {
        case .processRusage(let ids):
            if ids.count > HelperLimits.maxBatch {
                return invalid("Too many processes in one request (at most \(HelperLimits.maxBatch)).")
            }
            if ids.contains(where: { $0.pid <= 0 }) { return invalid("Process IDs must be positive.") }
        case .processDetails(let id, let parts):
            if id.pid <= 0 { return invalid("Process IDs must be positive.") }
            if parts.isEmpty { return invalid("Ask for at least one part of the process's details.") }
        case .sampleStacks(let id, let seconds):
            if id.pid <= 0 { return invalid("Process IDs must be positive.") }
            if !HelperLimits.sampleSeconds.contains(seconds) {
                return invalid("Sample for \(HelperLimits.sampleSeconds.lowerBound) to \(HelperLimits.sampleSeconds.upperBound) seconds.")
            }
        case .memoryFootprint(let id):
            if id.pid <= 0 { return invalid("Process IDs must be positive.") }
        case .hello, .status, .lock, .removeRightAndSettings, .setAgentContents,
             .listeningSockets, .internetSockets, .snapshotSizes, .deviceProfiles, .backgroundItems:
            break
        }
        return nil
    }

    /// pid 0 (kernel_task) and 1 (launchd) are critical whatever their name reads as.
    public static func isCritical(pid: Int32, name: String) -> Bool {
        pid <= 1 || criticalProcessNames.contains(name)
    }

    public static func criticalRefusal(_ name: String) -> HelperRefusal {
        HelperRefusal(code: .criticalProcess, message: "FlightDeck never samples \(name): pausing it would freeze the Mac.")
    }

    private static func invalid(_ message: String) -> HelperRefusal {
        HelperRefusal(code: .invalidParameter, message: message)
    }
}
