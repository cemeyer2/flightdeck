// GPU and display details for the GPU performance tab, collected once (a static on the GPU view) from Metal and AppKit.
import Metal
import AppKit
import FlightDeckCore

/// Static GPU/display facts from Metal and AppKit. `rows` are label/value pairs for display.
struct MetalInfo {
    var rows: [(String, String)] = []
    /// Recommended max working set of the first GPU, in bytes (Metal's guidance for how much memory a GPU app should use).
    var workingSet: UInt64?

    static func collect() -> MetalInfo {
        var m = MetalInfo()
        for d in MTLCopyAllDevices() {
            // Highest families first. Only the families listed here are reported.
            let families: [(MTLGPUFamily, String)] = [(.apple9, "Apple 9"), (.apple8, "Apple 8"), (.apple7, "Apple 7"), (.apple6, "Apple 6"),
                                                      (.mac2, "Mac 2"), (.metal3, "Metal 3")]
            let fam = families.filter { d.supportsFamily($0.0) }.map(\.1).joined(separator: ", ")
            m.workingSet = m.workingSet ?? d.recommendedMaxWorkingSetSize
            m.rows += [
                ("Name", d.name),
                ("GPU families", fam.isEmpty ? "—" : fam),
                ("Unified memory", d.hasUnifiedMemory ? "yes" : "no"),
                ("Recommended working set", Fmt.bytes(d.recommendedMaxWorkingSetSize)),
                // A snapshot at collection time, not live (the GPU tab collects this once).
                ("Currently allocated", Fmt.bytes(UInt64(d.currentAllocatedSize))),
                ("Max buffer", Fmt.bytes(UInt64(d.maxBufferLength))),
                ("Max threads / threadgroup", "\(d.maxThreadsPerThreadgroup.width)"),
                ("Ray tracing", d.supportsRaytracing ? "yes" : "no"),
                ("Dynamic libraries", d.supportsDynamicLibraries ? "yes" : "no"),
                ("Low power / headless / removable", "\(d.isLowPower ? "yes" : "no") / \(d.isHeadless ? "yes" : "no") / \(d.isRemovable ? "yes" : "no")"),
                ("Registry ID", String(format: "0x%llx", d.registryID)),
            ]
        }
        for (i, s) in NSScreen.screens.enumerated() {
            let px = s.convertRectToBacking(s.frame).size
            let hz = s.maximumFramesPerSecond
            let edr = s.maximumPotentialExtendedDynamicRangeColorComponentValue
            m.rows.append(("Display \(i + 1)", "\(s.localizedName) · \(Int(px.width))×\(Int(px.height)) px · \(hz) Hz" + (edr > 1 ? String(format: " · HDR (EDR %.0f×)", edr) : "")))
        }
        return m
    }
}
