import Foundation
import FlightDeckHelperProtocol

public typealias ConnectionID = UInt64

/// What a connection may read right now. full = it presented a verified authorization itself; counters = another
/// connection from the same uid holds one (standalone --mcp / --snapshot while the app is unlocked).
public enum Access: Sendable, Equatable { case none, counters, full }

/// Who holds an unlock. Lives only in the helper's memory and only as long as the holder's connection, so an idle
/// exit can't outlive or extend an unlock. Not thread-safe: HelperService serialises access.
public final class UnlockRegistry {
    private let clock: () -> Date
    /// uid → the connection that unlocked for it.
    private var holders: [uid_t: ConnectionID] = [:]
    private var verifiedAt: [ConnectionID: Date] = [:]
    /// Moves on each time a connection's unlock ends. Kept after a close (never removed), so a check that started
    /// before the close can't match a fresh 0; connection IDs aren't reused and the helper exits when idle.
    private var epochs: [ConnectionID: UInt64] = [:]

    public init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    /// `verified` = the presented external form passed `verify` (or the per-connection cache hit).
    public func access(connection: ConnectionID, uid: uid_t, verified: Bool) -> Access {
        if verified {
            holders[uid] = connection
            return .full
        }
        if let h = holders[uid], h != connection { return .counters }
        return .none
    }

    public func lock(connection: ConnectionID) { end(connection) }

    public func connectionClosed(_ c: ConnectionID) { end(c) }

    public func cachedVerification(connection: ConnectionID) -> Bool {
        guard let t = verifiedAt[connection] else { return false }
        return clock().timeIntervalSince(t) < HelperLimits.authReverifyInterval
    }

    public func recordVerification(connection: ConnectionID) { verifiedAt[connection] = clock() }

    /// A presented authorization no longer verifies (the right was revoked): the connection's unlock ends.
    public func verificationFailed(connection: ConnectionID) { end(connection) }

    public func holderAlive(uid: uid_t) -> Bool { holders[uid] != nil }

    /// Read before an authd check and compared after it: a different value means the unlock ended meanwhile.
    public func epoch(connection: ConnectionID) -> UInt64 { epochs[connection, default: 0] }

    private func end(_ c: ConnectionID) {
        epochs[c, default: 0] &+= 1
        verifiedAt[c] = nil
        for (uid, h) in holders where h == c { holders[uid] = nil }
    }
}
