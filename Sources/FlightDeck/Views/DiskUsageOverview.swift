import SwiftUI
import FlightDeckCore

// Disk Space › "What's using my disk": the startup-disk breakdown above the known space hogs. The breakdown loads when
// this mode is shown (diskutil and tmutil only, no folder access); the space hogs wait for Analyze.

/// The two modes of the Disk Space page.
enum DiskSpaceMode: String, CaseIterable, Identifiable {
    case usage = "What's Using My Disk", folders = "Folder Scanner"
    var id: String { rawValue }
}

struct DiskUsageOverview: View {
    @ObservedObject var model = StorageModel.shared
    var body: some View {
        MaybeScroll {
            VStack(spacing: 12) {
                StorageBreakdownPanel(model: model)
                SpaceHogsPanel(model: model)
            }
        }
        .onAppear { model.loadBreakdown() }
    }
}
