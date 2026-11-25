// Settings › Integrations › Chrome tabs: the switch, one status line and the guided "Load unpacked" setup for the
// FlightDeck Tabs extension. Chrome's install warning is explained before anything is installed.
import SwiftUI
import FlightDeckCore

struct ChromeTabsSettingsSection: View {
    @ObservedObject private var service = ChromeTabsService.shared

    var body: some View {
        let status = service.status
        Section("Chrome tabs") {
            Toggle("Name the Chrome tab behind each Chrome process", isOn: $service.enabled).disabled(Demo.isEnabled)
            if service.enabled && !Demo.isEnabled {
                Text(status.text).font(.caption).monospacedDigit()
                HStack {
                    Button("Set up…") { service.setUp() }
                        .disabled(status == .unbundled || !service.relocatable)
                        .help(status == .unbundled ? status.text : "Copies the extension to a folder of its own, shows it in Finder and opens chrome://extensions")
                    Button("Open chrome://extensions") { ChromeTabsService.openExtensionsPage() }
                }
                if status == .notSetUp || status == .waiting || status == .unbundled {
                    Text("Chrome will warn that this extension can “Read your browsing history”. It needs the tabs and webNavigation permissions to see which tab runs in which process. Tab titles and addresses stay in FlightDeck's memory and are never saved or shared; AI assistants see only site names.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("After Set up: in chrome://extensions turn on Developer mode, click Load unpacked and choose the ChromeExtension folder FlightDeck showed in Finder. Chrome shows warnings about developer-mode extensions; that is expected for an extension loaded this way.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if status == .waiting {
                    Text("If it never connects, your organisation may block developer mode or unpacked extensions (chrome://policy).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if !Demo.isEnabled {
                Text("Off by default. Shows which Chrome tab each Chrome process is running, using a small FlightDeck Tabs extension. If you used it before, remove FlightDeck Tabs in chrome://extensions.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not available in demo mode.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
