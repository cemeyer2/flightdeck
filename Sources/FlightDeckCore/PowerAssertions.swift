import Foundation
import IOKit.pwr_mgt

// Answers "why won't my Mac sleep?". Sampler (Snapshot.swift) calls PowerAssertions.byPID() every sample and attaches
// the result to each ProcessSample.powerAssertions, which feeds the Analyzer "keeping the Mac awake" findings,
// the Sleep column/filter in the process list and the inspector.
/// Who is keeping the Mac (or its display) awake: power assertions by process (public IOKit API).
public struct PowerAssertion: Codable, Sendable, Hashable {
    public var type: String          // e.g. PreventUserIdleSystemSleep
    public var name: String          // the reason the app gave
    /// True for the modern system-sleep assertion types (PreventUserIdleSystemSleep, PreventSystemSleep) and the
    /// legacy NoIdleSleepAssertion name that older apps still create.
    public var preventsSystemSleep: Bool { type.contains("SystemSleep") || type == "NoIdleSleepAssertion" || type == "PreventSystemSleep" }
    /// True for PreventUserIdleDisplaySleep and the legacy NoDisplaySleepAssertion.
    public var preventsDisplaySleep: Bool { type.contains("DisplaySleep") || type == "NoDisplaySleepAssertion" }
    /// Short human phrase for the UI. Display sleep is checked first because keeping the display awake also keeps
    /// the system awake, so it is the more specific (and more visible) effect.
    public var label: String {
        if preventsDisplaySleep { return "keeps the display awake" }
        if preventsSystemSleep { return "prevents sleep" }
        return type
    }
}

/// Reads power assertions from powerd via IOPMCopyAssertionsByProcess (public, no root needed).
public enum PowerAssertions {
    /// Sleep-preventing assertions grouped by PID. Assertions that don't affect sleep (e.g. background-task or
    /// user-active markers) are filtered out, and PIDs left with none are omitted, so a missing PID means "not
    /// keeping the Mac awake". Returns an empty dictionary if powerd can't be queried.
    public static func byPID() -> [Int32: [PowerAssertion]] {
        var dict: Unmanaged<CFDictionary>?
        // The Copy-rule result is +1 retained, hence takeRetainedValue. Its shape is
        // { pid (CFNumber): [ { "AssertType": ..., "AssertName": ..., ... } ] }.
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess, let d = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [:] }
        var out: [Int32: [PowerAssertion]] = [:]
        for (pid, list) in d {
            let a = list.compactMap { x -> PowerAssertion? in
                guard let t = x["AssertType"] as? String else { return nil }
                return PowerAssertion(type: t, name: (x["AssertName"] as? String) ?? "")
            }.filter { $0.preventsSystemSleep || $0.preventsDisplaySleep }
            if !a.isEmpty { out[pid.int32Value] = a }
        }
        return out
    }
}
