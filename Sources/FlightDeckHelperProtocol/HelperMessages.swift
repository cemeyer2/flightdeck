import Foundation

/// PID + start time, the same shape as FlightDeckCore's ProcessIdentity (which this target can't see). Every
/// per-process request carries one so the helper can refuse a recycled PID.
public struct HelperProcessID: Codable, Sendable, Hashable {
    public var pid: Int32
    public var startTime: UInt64   // microseconds since epoch
    public init(pid: Int32, startTime: UInt64) { self.pid = pid; self.startTime = startTime }
}

/// Parts of another process's contents the app may ask for. Contents are live-only and never persisted.
public enum DetailPart: String, Codable, Sendable, CaseIterable { case args, env, cwd, files, sockets }

/// The fixed set of requests. None takes a command, a path or free-form arguments; per-process requests take a
/// typed identity, and the only numbers are validated (see HelperValidation).
public enum HelperRequest: Codable, Sendable, Equatable {
    case hello(version: Int), status, lock, removeRightAndSettings, setAgentContents(Bool)
    case processRusage(ids: [HelperProcessID])
    case processDetails(id: HelperProcessID, parts: Set<DetailPart>)
    case listeningSockets, internetSockets, snapshotSizes, deviceProfiles, backgroundItems
    case sampleStacks(id: HelperProcessID, seconds: Int), memoryFootprint(id: HelperProcessID)
}

/// What travels over XPC: a request plus, for root data, the AuthorizationExternalForm bytes. Those bytes are a
/// bearer handle: never written, logged or put into an error message.
public struct HelperEnvelope: Codable, Sendable {
    public var request: HelperRequest
    public var authorization: Data?
    public init(request: HelperRequest, authorization: Data?) { self.request = request; self.authorization = authorization }
}

/// Cumulative counters for one process, as proc_pid_rusage (and task info, for threads) report them to root.
public struct HelperRusage: Codable, Sendable, Hashable {
    public var cpuNs: UInt64, diskRead: UInt64, diskWritten: UInt64, energyNJ: UInt64, idleWakeups: UInt64
    public var physFootprint: UInt64, threads: Int?
    public init(cpuNs: UInt64, diskRead: UInt64, diskWritten: UInt64, energyNJ: UInt64, idleWakeups: UInt64,
                physFootprint: UInt64, threads: Int?) {
        self.cpuNs = cpuNs; self.diskRead = diskRead; self.diskWritten = diskWritten; self.energyNJ = energyNJ
        self.idleWakeups = idleWakeups; self.physFootprint = physFootprint; self.threads = threads
    }
}

public struct HelperRusageEntry: Codable, Sendable, Hashable {
    public var id: HelperProcessID
    public var rusage: HelperRusage
    public init(id: HelperProcessID, rusage: HelperRusage) { self.id = id; self.rusage = rusage }
}

/// Another process's contents (tier X). Only the parts asked for are filled; nil = not asked or not readable.
public struct HelperProcessContents: Codable, Sendable, Hashable {
    public var args: [String]?, env: [String]?, cwd: String?
    public var files: [String]?, sockets: [String]?   // display strings
    public init(args: [String]? = nil, env: [String]? = nil, cwd: String? = nil, files: [String]? = nil,
                sockets: [String]? = nil) {
        self.args = args; self.env = env; self.cwd = cwd; self.files = files; self.sockets = sockets
    }
}

public struct HelperHello: Codable, Sendable, Hashable {
    public var version: Int
    /// The administrator right is defined as expected. The app never prompts until this is true.
    public var rightInPlace: Bool
    public var eligible: Bool
    public init(version: Int, rightInPlace: Bool, eligible: Bool) {
        self.version = version; self.rightInPlace = rightInPlace; self.eligible = eligible
    }
}

public struct HelperServiceStatus: Codable, Sendable, Hashable {
    /// This connection holds a verified unlock.
    public var unlocked: Bool
    /// Some connection from the caller's uid holds one (standalone --mcp gets counters while it does).
    public var holderAlive: Bool
    /// "Let AI agents read other processes' details", stored by the helper in a root-owned file.
    public var agentContents: Bool
    public init(unlocked: Bool, holderAlive: Bool, agentContents: Bool) {
        self.unlocked = unlocked; self.holderAlive = holderAlive; self.agentContents = agentContents
    }
}

/// Why the helper declined a request. `message` is a plain sentence for the UI and MCP.
public struct HelperRefusal: Error, Codable, Sendable, Hashable {
    public enum Code: String, Codable, Sendable {
        case versionMismatch, helloRequired, notAuthorized, notHolder, invalidParameter, criticalProcess,
             processChanged, busy, rateLimited, outputTooLarge, toolFailed, notEligible, bundleMissing
    }
    public var code: Code
    public var message: String
    public init(code: Code, message: String) { self.code = code; self.message = message }
}

public enum HelperResponse: Codable, Sendable, Equatable {
    case hello(HelperHello), status(HelperServiceStatus), ok
    case rusage([HelperRusageEntry]), contents(HelperProcessContents), toolText(String)
    case snapshotSizes([SnapshotSize]), profiles([DeviceProfile]), backgroundItems([BackgroundItem])
    case refused(HelperRefusal)
}

/// JSON with sorted keys, so the same value always encodes to the same bytes.
public enum HelperWire {
    public static func encode<T: Encodable>(_ v: T) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(v)) ?? Data()
    }
    public static func decode<T: Decodable>(_ t: T.Type, _ d: Data) -> T? {
        try? JSONDecoder().decode(t, from: d)
    }
}
