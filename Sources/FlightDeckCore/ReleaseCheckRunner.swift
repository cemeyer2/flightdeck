// One update check end to end, with the network and the notification passed in so the sequence is testable: at most
// one run at a time; the single retry without an ETag after a 304 with nothing cached; anything changed during the
// request that the response doesn't own (the permission flag) is kept; the result is saved before notifying; and a
// version is marked notified only after the post returns true. ReleaseCheckModel is a thin adapter over this.
import Foundation

@MainActor
public final class ReleaseCheckRunner {
    /// Called before `state` or `inFlight` changes (the model forwards it to `objectWillChange`).
    public var willChange: () -> Void = {}
    public private(set) var state: ReleaseCheckState { willSet { willChange() } }
    public private(set) var inFlight = false { willSet { willChange() } }

    private let now: () -> Date
    private let fetch: (String?) async -> ReleaseHTTPResponse
    private let post: (ReleaseNotice) async -> Bool
    private let save: (ReleaseCheckState) -> Void

    public init(state: ReleaseCheckState, now: @escaping () -> Date = Date.init,
                fetch: @escaping (_ etag: String?) async -> ReleaseHTTPResponse,
                post: @escaping (ReleaseNotice) async -> Bool,
                save: @escaping (ReleaseCheckState) -> Void) {
        self.state = state
        self.now = now
        self.fetch = fetch
        self.post = post
        self.save = save
    }

    /// Changes the state outside a check (e.g. the permission flag) and saves it.
    public func update(_ change: (inout ReleaseCheckState) -> Void) {
        change(&state)
        save(state)
    }

    /// One check. Does nothing while another is in flight. `alertsEnabled` is read once the response has arrived.
    public func run(installed: ReleaseVersion, alertsEnabled: () -> Bool) async {
        guard !inFlight else { return }
        inFlight = true; defer { inFlight = false }
        var (s, outcome) = ReleaseCheck.next(state: state, response: await fetch(state.etag), now: now())
        if outcome == .retryWithoutETag {
            s = ReleaseCheck.next(state: s, response: await fetch(nil), now: now()).state
        }
        s.permissionRequested = state.permissionRequested
        state = s
        save(state)
        guard let notice = ReleaseCheck.notice(latest: state.latest, installed: installed, lastNotified: state.lastNotifiedVersion,
                                               alertsEnabled: alertsEnabled()) else { return }
        let delivered = await post(notice)
        state.markNotified(notice, delivered: delivered)
        save(state)
    }
}
