import Foundation
import IOKit.pwr_mgt

/// Who is keeping the Mac (or its display) awake: power assertions by process (public IOKit API).
public struct PowerAssertion: Codable, Sendable, Hashable {
    public var type: String          // e.g. PreventUserIdleSystemSleep
    public var name: String          // the reason the app gave
    public var preventsSystemSleep: Bool { type.contains("SystemSleep") || type == "NoIdleSleepAssertion" || type == "PreventSystemSleep" }
    public var preventsDisplaySleep: Bool { type.contains("DisplaySleep") || type == "NoDisplaySleepAssertion" }
    public var label: String {
        if preventsDisplaySleep { return "keeps the display awake" }
        if preventsSystemSleep { return "prevents sleep" }
        return type
    }
}

public enum PowerAssertions {
    public static func byPID() -> [Int32: [PowerAssertion]] {
        var dict: Unmanaged<CFDictionary>?
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
