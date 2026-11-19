import Foundation
import Darwin
import dnssd
// Destinations, part 4: names for remote IPs by reverse DNS (PTR records), looked up in the background. Sampling never
// waits for a name: the tracker asks with `request`, and `onName` reports the answer later, on the namer's queue.
//
// Why reverse DNS only: macOS gives an unprivileged app no way to see which host name another app resolved before
// connecting (nettop and libproc show addresses only; DNS answers are cached inside mDNSResponder, and reading them
// needs a DNS proxy or content filter Network Extension). So the name shown is the PTR record of the IP, which can
// be missing, generic ("ec2-…amazonaws.com") or simply what the IP's owner chose to publish; the UI says so.
//
// Lookups use dns_sd (DNSServiceQueryRecord) rather than getnameinfo, because a dns_sd query is asynchronous and can
// be cancelled, so a slow DNS server costs a cancelled query after `timeout`, never a blocked thread. They're
// rate-limited (at most `maxInFlight` at once, at least `spacing` apart) and the queue is bounded; answers are cached,
// names for `positiveTTL` and "no name" for `negativeTTL`, in a bounded cache.

public final class HostNamer: @unchecked Sendable {
    public struct Config: Sendable {
        public var timeout: TimeInterval = 5
        public var maxInFlight = 4
        public var spacing: TimeInterval = 0.1
        public var maxQueued = 500
        public var maxCache = 5000
        public var positiveTTL: TimeInterval = 6 * 3600
        public var negativeTTL: TimeInterval = 3600
        public init() {}
    }
    /// Looks up one IP and calls back exactly once with the name (nil: none, failed or timed out). Injected by tests.
    public typealias Lookup = (_ ip: String, _ timeout: TimeInterval, _ queue: DispatchQueue, _ done: @escaping @Sendable (String?) -> Void) -> Void

    public let config: Config
    /// Called on the namer's queue with (ip, name or nil) when a lookup finishes.
    public var onName: ((String, String?) -> Void)?
    private let queue = DispatchQueue(label: "flightdeck.destinations.rdns", qos: .utility)
    private let lookup: Lookup
    /// Answers, guarded by `cacheLock` (not the queue): the tracker reads it while holding its own lock, and the queue
    /// calls into the tracker, so reading through `queue.sync` there could deadlock.
    private var cache: [String: (name: String?, at: Date)] = [:]
    private let cacheLock = NSLock()
    // All below only touched on `queue`.
    private var pending: [String] = []
    private var queued: Set<String> = []
    private var inFlight = 0
    private var lastStart = Date.distantPast
    private var timerArmed = false

    public init(config: Config = Config(), lookup: @escaping Lookup = HostNamer.reverseDNS) {
        self.config = config; self.lookup = lookup
    }

    /// The cached answer for `ip`, if there is a fresh one: .some(name) or .some(nil) for "no name". Thread-safe.
    public func cached(_ ip: String) -> String?? { fresh(ip).map { $0.name } }

    private func fresh(_ ip: String) -> (name: String?, at: Date)? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let c = cache[ip] else { return nil }
        let ttl = c.name == nil ? config.negativeTTL : config.positiveTTL
        return Date().timeIntervalSince(c.at) < ttl ? c : nil
    }

    /// Asks for a name. Returns at once; the answer arrives through `onName` (immediately, on the queue, if cached).
    /// Requests beyond `maxQueued` are dropped: the row then stays "not looked up" (shown as such, never as "no name").
    public func request(_ ip: String) {
        queue.async { [self] in
            if let c = fresh(ip) { onName?(ip, c.name); return }
            guard !queued.contains(ip), pending.count < config.maxQueued else { return }
            queued.insert(ip); pending.append(ip)
            pump()
        }
    }

    /// Starts queued lookups while slots are free, keeping `spacing` between starts; re-arms itself when it has to wait.
    private func pump() {
        while inFlight < config.maxInFlight, !pending.isEmpty {
            let wait = config.spacing - Date().timeIntervalSince(lastStart)
            if wait > 0 {
                if !timerArmed { timerArmed = true; queue.asyncAfter(deadline: .now() + wait) { [self] in timerArmed = false; pump() } }
                return
            }
            let ip = pending.removeFirst()
            inFlight += 1; lastStart = Date()
            lookup(ip, config.timeout, queue) { [self] name in
                // Lookups call back on `queue` (the real one does; test lookups are given the queue to use).
                inFlight -= 1; queued.remove(ip)
                let n = name.flatMap(DomainName.normalize)
                cacheLock.lock()
                cache[ip] = (n, Date())
                if cache.count > config.maxCache { trimCache() }
                cacheLock.unlock()
                onName?(ip, n)
                pump()
            }
        }
    }

    /// Drops the oldest quarter of the cache (rare: only once more than `maxCache` IPs were looked up). Under cacheLock.
    private func trimCache() {
        let drop = cache.sorted { $0.value.at < $1.value.at }.prefix(cache.count / 4).map(\.key)
        for k in drop { cache[k] = nil }
    }

    /// Waits until queued and running lookups have finished (tests).
    func drain(timeout: TimeInterval = 10) {
        let until = Date().addingTimeInterval(timeout)
        while Date() < until, queue.sync(execute: { inFlight > 0 || !pending.isEmpty }) { Thread.sleep(forTimeInterval: 0.02) }
    }

    // MARK: The real lookup

    /// "4.3.2.1.in-addr.arpa." / nibble-reversed "….ip6.arpa." for an IP; nil if it doesn't parse.
    public static func ptrName(_ ip: String) -> String? {
        let bare = ip.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ip
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            return withUnsafeBytes(of: v4.s_addr) { $0.reversed().map { String($0) }.joined(separator: ".") } + ".in-addr.arpa."
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, bare, &v6) == 1 else { return nil }
        let hex = withUnsafeBytes(of: v6) { b in b.flatMap { [$0 >> 4, $0 & 0xf] } }
        return hex.reversed().map { String($0, radix: 16) }.joined(separator: ".") + ".ip6.arpa."
    }

    /// Decodes a DNS wire-format name (length-prefixed labels, as in PTR record data). nil if malformed or compressed.
    static func decodeName(_ data: UnsafeRawBufferPointer) -> String? {
        var labels: [String] = [], i = 0
        while i < data.count {
            let n = Int(data[i]); i += 1
            if n == 0 { return labels.isEmpty ? nil : labels.joined(separator: ".") }
            guard n < 64, i + n <= data.count else { return nil }
            labels.append(String(decoding: data[i..<(i + n)], as: UTF8.self)); i += n
        }
        return nil
    }

    /// One query's state, kept alive (retained through the dns_sd context pointer) until it finishes or times out.
    private final class Query {
        var ref: DNSServiceRef?
        var done: (@Sendable (String?) -> Void)?
        func finish(_ name: String?) {
            guard let d = done else { return }
            done = nil
            if let ref { DNSServiceRefDeallocate(ref); self.ref = nil }
            d(name)
            Unmanaged.passUnretained(self).release()   // balances passRetained in reverseDNS
        }
    }

    /// The real lookup: a PTR query through mDNSResponder, answered on `queue`, cancelled after `timeout`.
    public static func reverseDNS(_ ip: String, timeout: TimeInterval, queue: DispatchQueue, done: @escaping @Sendable (String?) -> Void) {
        guard let ptr = ptrName(ip) else { queue.async { done(nil) }; return }
        let q = Query()
        q.done = done
        let ctx = Unmanaged.passRetained(q).toOpaque()
        // The callback is a C function pointer, so it can't capture: the Query comes back through `context`.
        let callback: DNSServiceQueryRecordReply = { _, _, _, err, _, _, _, len, rdata, _, context in
            guard let context else { return }
            let q = Unmanaged<Query>.fromOpaque(context).takeUnretainedValue()
            var name: String?
            if err == kDNSServiceErr_NoError, let rdata { name = HostNamer.decodeName(UnsafeRawBufferPointer(start: rdata, count: Int(len))) }
            q.finish(name)   // the first answer is enough
        }
        var ref: DNSServiceRef?
        let err = DNSServiceQueryRecord(&ref, 0, 0, ptr, UInt16(kDNSServiceType_PTR), UInt16(kDNSServiceClass_IN), callback, ctx)
        guard err == kDNSServiceErr_NoError, let ref else {
            queue.async { q.finish(nil) }; return
        }
        q.ref = ref
        DNSServiceSetDispatchQueue(ref, queue)
        queue.asyncAfter(deadline: .now() + timeout) { q.finish(nil) }
    }
}
