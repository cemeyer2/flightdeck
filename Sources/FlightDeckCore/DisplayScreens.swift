import AppKit
// NSScreen's facts for each screen (refresh range, EDR headroom, colour profile name). AppKit wants the main thread,
// so callers off it (the MCP tool) hop there first; both the app and `--mcp` service the main queue.

public enum DisplayScreens {
    @MainActor public static func read() -> [DisplayScreenFacts] {
        NSScreen.screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayScreenFacts(displayID: n.uint32Value, name: s.localizedName, maximumFPS: s.maximumFramesPerSecond,
                                      minimumRefreshInterval: s.minimumRefreshInterval, maximumRefreshInterval: s.maximumRefreshInterval,
                                      updateGranularity: s.displayUpdateGranularity,
                                      edrNow: Double(s.maximumExtendedDynamicRangeColorComponentValue),
                                      edrPotential: Double(s.maximumPotentialExtendedDynamicRangeColorComponentValue),
                                      edrReference: Double(s.maximumReferenceExtendedDynamicRangeColorComponentValue),
                                      colorSpace: s.colorSpace?.localizedName, backingScale: Double(s.backingScaleFactor))
        }
    }
}
