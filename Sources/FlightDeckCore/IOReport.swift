import Foundation

// Used by GPUSampler for GPU/CPU P-state residency and energy (Energy Model) channels. IOReport is a private dylib
// with no headers, so every function is resolved with dlsym and declared below with its reverse-engineered signature.
/// Thin wrapper over the private libIOReport (what `powermetrics` uses), resolved at runtime and readable
/// without root on Apple silicon. Each `sample()` returns the delta since the previous call.
/// Not thread-safe; confine to one queue.
public final class IOReportSampler: @unchecked Sendable {
    // Signatures (all CF objects; "Copy"/"Create" results are +1 retained, "Get" results are not):
    // CopyChannelsInGroup(group, subgroup, 0, 0, 0) -> channel dictionary; MergeChannels(into, from, nil);
    // CreateSubscription(nil, channels, &subscribedChannels, 0, nil) -> subscription; CreateSamples(sub, chans, nil);
    // CreateSamplesDelta(prev, cur, nil); the Channel*/State*/Simple* accessors read one channel dictionary.
    typealias CopyChans = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    typealias Merge = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    typealias Sub = @convention(c) (CFTypeRef?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    typealias Samples = @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias Str = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias I64 = @convention(c) (CFDictionary, Int32) -> Int64
    typealias Cnt = @convention(c) (CFDictionary) -> Int32
    typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    typealias Format = @convention(c) (CFDictionary) -> UInt8   // 1 simple, 2 state, 3 histogram

    /// The resolved function table; nil (via `fns`) if any symbol is missing, which makes the sampler unavailable.
    struct Fns {
        let copy: CopyChans, merge: Merge, sub: Sub, samples: Samples, delta: Delta
        let group: Str, subgroup: Str, name: Str, unit: Str, simple: I64, count: Cnt, stateName: StateName, residency: I64, format: Format
    }

    /// One channel's change over the last interval. `unit` is the channel's own label (e.g. "mJ", "nJ" for energy);
    /// `states` lists each state's residency for state-format channels (in the channel's time units, usually comparable
    /// only as fractions of the total). Histogram channels are reported with neither a value nor states.
    public struct Channel: Sendable {
        public var group: String, subgroup: String, name: String, unit: String
        public var value: Int64                       // simple channels (e.g. energy since last sample)
        public var states: [(name: String, residency: Int64)]   // state channels
    }

    private let fns: Fns?
    private var subscription: AnyObject?
    private var subscribed: CFMutableDictionary?
    private var last: CFDictionary?
    private var lastTime: Date?

    /// Subscribes to every channel in `groups` (merged into one subscription so a single sample covers all of them).
    /// Groups that don't exist on this Mac (e.g. on Intel) are skipped; with none left, `isAvailable` is false.
    public init(groups: [String] = ["Energy Model", "GPU Stats", "CPU Stats"]) {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { fns = nil; return }
        func f<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
        guard let copy = f("IOReportCopyChannelsInGroup", CopyChans.self), let merge = f("IOReportMergeChannels", Merge.self),
              let sub = f("IOReportCreateSubscription", Sub.self), let samples = f("IOReportCreateSamples", Samples.self),
              let delta = f("IOReportCreateSamplesDelta", Delta.self), let group = f("IOReportChannelGetGroup", Str.self),
              let subgroup = f("IOReportChannelGetSubGroup", Str.self), let name = f("IOReportChannelGetChannelName", Str.self),
              let unit = f("IOReportChannelGetUnitLabel", Str.self), let simple = f("IOReportSimpleGetIntegerValue", I64.self),
              let count = f("IOReportStateGetCount", Cnt.self), let stateName = f("IOReportStateGetNameForIndex", StateName.self),
              let residency = f("IOReportStateGetResidency", I64.self), let format = f("IOReportChannelGetFormat", Format.self) else { fns = nil; return }
        fns = Fns(copy: copy, merge: merge, sub: sub, samples: samples, delta: delta, group: group, subgroup: subgroup, name: name,
                  unit: unit, simple: simple, count: count, stateName: stateName, residency: residency, format: format)
        var all: CFMutableDictionary?
        for g in groups {
            guard let ch = copy(g as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let all { merge(all, ch, nil) } else { all = ch }
        }
        guard let all else { return }
        var subbed: Unmanaged<CFMutableDictionary>?
        subscription = sub(nil, all, &subbed, 0, nil)?.takeRetainedValue()
        subscribed = subbed?.takeRetainedValue()
    }

    /// False when libIOReport or the requested groups are missing; callers then report the derived values unavailable.
    public var isAvailable: Bool { subscription != nil }

    /// Channels changed since the previous call, and the elapsed time. nil on the first call.
    public func sample() -> (channels: [Channel], dt: TimeInterval)? {
        guard let fns, let subscription, let subscribed, let now = fns.samples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
        let t = Date()
        // IOReport counters are cumulative; the library's delta of two snapshots gives per-interval values. The new snapshot
        // always becomes the baseline, even if building this delta fails, so one bad sample doesn't break the next.
        defer { last = now; lastTime = t }
        guard let last, let lastTime, let d = fns.delta(last, now, nil)?.takeRetainedValue() as NSDictionary?,
              let items = d["IOReportChannels"] as? [CFDictionary] else { return nil }
        func s(_ f: Str, _ i: CFDictionary) -> String { f(i)?.takeUnretainedValue() as String? ?? "" }
        let chans = items.map { i -> Channel in
            let isState = fns.format(i) == 2
            let n = isState ? fns.count(i) : 0
            let states = n > 0 ? (0..<n).map { (s2: Int32) in (name: fns.stateName(i, s2)?.takeUnretainedValue() as String? ?? "", residency: fns.residency(i, s2)) } : []
            return Channel(group: s(fns.group, i), subgroup: s(fns.subgroup, i), name: s(fns.name, i), unit: s(fns.unit, i),
                           value: fns.format(i) == 1 ? fns.simple(i, 0) : 0, states: states)
        }
        return (chans, t.timeIntervalSince(lastTime))
    }
}
