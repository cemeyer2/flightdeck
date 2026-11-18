// Settings › Network: the opt-in speed-test schedule. Stored as hours in UserDefaults
// (`SpeedTestSchedule.defaultsKey`), which InternetModel reads at each once-a-minute check.
import SwiftUI
import FlightDeckCore

struct SpeedTestSettingsSection: View {
    @AppStorage(SpeedTestSchedule.defaultsKey) private var hours = 0

    var body: some View {
        Section("Internet speed test") {
            Picker("Run a speed test automatically", selection: $hours) {
                Text("Never").tag(0); Text("Every hour").tag(1); Text("Every 3 hours").tag(3); Text("Every 6 hours").tag(6)
            }
            Text("Off by default. Each test uses macOS's networkQuality for about 15–20 s and transfers real data (hundreds of MB on a fast line). Scheduled tests only run while FlightDeck runs, and are skipped on battery below 20%, on hotspots and metered connections, and in Low Data Mode. Results are kept for 90 days on this Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
