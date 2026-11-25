// The update check's one request: an unauthenticated GET of this repo's latest release on api.github.com. It carries
// nothing about this Mac or this copy (the User-Agent has no version), uses an ephemeral session with no cache or
// cookies, and sends If-None-Match when a result is cached, so an unchanged release costs nothing against the rate limit.
import Foundation

public final class ReleaseCheckClient: Sendable {
    public static let endpoint = URL(string: "https://api.github.com/repos/\(ReleaseCheck.owner)/\(ReleaseCheck.repo)/releases/latest")!
    private let session: URLSession
    private let timeout: TimeInterval

    /// `protocolClasses` lets tests route the request to a URLProtocol stub; nothing in the app sets it.
    public init(timeout: TimeInterval = 15, protocolClasses: [AnyClass]? = nil) {
        self.timeout = timeout
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        if let protocolClasses { c.protocolClasses = protocolClasses }
        session = URLSession(configuration: c)
    }
    deinit { session.invalidateAndCancel() }

    public func fetchLatest(etag: String?) async -> ReleaseHTTPResponse {
        var r = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("FlightDeck", forHTTPHeaderField: "User-Agent")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .transport(.badServerResponse) }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { if let k = k as? String { headers[k] = "\(v)" } }
            return .http(status: http.statusCode, headers: headers, body: data)
        } catch let e as URLError {
            return .transport(e.code)
        } catch {
            return .transport(.unknown)
        }
    }
}
