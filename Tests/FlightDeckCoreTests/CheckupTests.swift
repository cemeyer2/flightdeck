// Tests for the Checkup parsers and verdicts, using captured tool output (serials, addresses and names replaced), plus
// live smoke tests that skip when a tool or the hardware isn't there (CI runs on VMs: no battery, no Bluetooth).
import XCTest
@testable import FlightDeckCore

final class CheckupParseTests: XCTestCase {
    func testFileVault() {
        XCTAssertEqual(CheckupParse.fileVault("FileVault is On.\n"), .on)
        XCTAssertEqual(CheckupParse.fileVault("FileVault is Off.\n"), .off)
        XCTAssertEqual(CheckupParse.fileVault("FileVault is On.\nEncryption in progress: Percent completed = 34\n"), .encrypting(34))
        XCTAssertEqual(CheckupParse.fileVault("FileVault is Off.\nDecryption in progress: Percent completed = 80\n"), .decrypting(80))
        XCTAssertEqual(CheckupParse.fileVault(""), .unknown)
        XCTAssertEqual(CheckupRules.fileVault(nil).status, .unknown)
        XCTAssertEqual(CheckupRules.fileVault("FileVault is Off.").status, .attention)
    }

    func testGatekeeperAndFirewall() {
        XCTAssertEqual(CheckupParse.gatekeeper("assessments enabled\n"), true)
        XCTAssertEqual(CheckupParse.gatekeeper("assessments disabled\n"), false)
        XCTAssertNil(CheckupParse.gatekeeper(""))
        XCTAssertEqual(CheckupParse.firewallState("Firewall is disabled. (State = 0)\n"), 0)
        XCTAssertEqual(CheckupParse.firewallState("Firewall is enabled. (State = 1)\n"), 1)
        XCTAssertEqual(CheckupParse.firewallState("Firewall is blocking all non-essential incoming connections. (State = 2)"), 2)
        XCTAssertEqual(CheckupParse.stealthMode("Firewall stealth mode is off\n"), false)
        XCTAssertEqual(CheckupRules.firewall(state: "Firewall is disabled. (State = 0)", stealth: nil).status, .attention)
        XCTAssertEqual(CheckupRules.firewall(state: "Firewall is enabled. (State = 1)", stealth: "Firewall stealth mode is on").status, .pass)
        XCTAssertEqual(CheckupRules.firewall(state: "", stealth: nil).status, .unknown)
        XCTAssertEqual(CheckupRules.sip("System Integrity Protection status: enabled.").status, .pass)
        XCTAssertEqual(CheckupRules.sip("System Integrity Protection status: disabled.").status, .attention)
    }

    func testSecureBoot() throws {
        let json = """
        {"SPiBridgeDataType":[{"ibridge_build":"mBoot-1","ibridge_sb_other_kext":"Yes","ibridge_sb_sip":"Enabled","ibridge_secure_boot":"Reduced Security"}]}
        """
        let sb = try XCTUnwrap(CheckupParse.secureBoot(Data(json.utf8)))
        XCTAssertEqual(sb.level, "Reduced Security"); XCTAssertEqual(sb.otherKexts, true)
        XCTAssertEqual(CheckupRules.secureBoot(sb).status, .attention)
        XCTAssertEqual(CheckupRules.secureBoot(("Full Security", false)).status, .pass)
        XCTAssertEqual(CheckupRules.secureBoot(nil).status, .unknown)
        XCTAssertNil(CheckupParse.secureBoot(Data(#"{"SPiBridgeDataType":[]}"#.utf8)))
    }

    func testSoftwareUpdate() {
        let d: [String: Any] = ["AutomaticDownload": true, "AutomaticallyInstallMacOSUpdates": false,
                                "RecommendedUpdates": [["Display Name": "macOS 27.2.1", "Display Version": "27.2.1"]],
                                "LastSuccessfulDate": Date(timeIntervalSince1970: 1_000_000)]
        let p = CheckupParse.updatePrefs(d)
        XCTAssertNil(p.criticalUpdateInstall); XCTAssertEqual(p.recommended, ["macOS 27.2.1"])
        XCTAssertEqual(CheckupRules.autoUpdates(p).status, .pass)   // absent keys = macOS defaults (on)
        var off = p; off.criticalUpdateInstall = false
        XCTAssertEqual(CheckupRules.autoUpdates(off).status, .attention)
        XCTAssertEqual(CheckupRules.pendingUpdates(p, live: nil, liveError: nil).status, .attention)
        XCTAssertEqual(CheckupRules.pendingUpdates(p, live: [], liveError: nil).status, .pass)
        XCTAssertEqual(CheckupRules.pendingUpdates(nil, live: nil, liveError: nil).status, .unknown)

        let list = """
        Software Update Tool

        Finding available software
        Software Update found the following new or updated software:
        * Label: macOS Tahoe 26.2-25C56
        \tTitle: macOS Tahoe 26.2, Version: 26.2, Size: 3502345KiB, Recommended: YES, Action: restart,
        * Label: Safari26.2-26.2
        \tTitle: Safari, Version: 26.2, Size: 190000KiB, Recommended: YES,
        """
        XCTAssertEqual(CheckupParse.softwareUpdateList(list), ["macOS Tahoe 26.2", "Safari"])
        XCTAssertEqual(CheckupParse.softwareUpdateList("Software Update Tool\n\nFinding available software\nNo new software available.\n"), [])
        XCTAssertNil(CheckupParse.softwareUpdateList("Software Update Tool\n\nCan't connect to the Apple Software Update server.\n"))
    }

    func testTimeMachine() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let d: [String: Any] = ["AutoBackup": 1, "Destinations": [
            ["SnapshotDates": [now.addingTimeInterval(-10 * 86_400), now.addingTimeInterval(-3600)]],
            ["SnapshotDates": [now.addingTimeInterval(-5 * 86_400)]]]]
        let tm = CheckupParse.timeMachine(d)
        XCTAssertEqual(tm.destinations, 2); XCTAssertEqual(tm.autoBackup, true); XCTAssertEqual(tm.latest, now.addingTimeInterval(-3600))
        XCTAssertEqual(CheckupRules.timeMachine(tm, tmutil: nil, now: now).status, .pass)
        XCTAssertEqual(CheckupRules.timeMachine(tm, tmutil: nil, now: now.addingTimeInterval(5 * 86_400)).status, .attention)
        XCTAssertEqual(CheckupRules.timeMachine(CheckupParse.timeMachine([:]), tmutil: nil).value, "Not set up")
        XCTAssertEqual(CheckupRules.timeMachine(nil, tmutil: nil).status, .unknown)

        let path = "/Volumes/.timemachine/14D48173-0000-0000-0000-000000000000/2026-11-16-090919.backup/2026-11-16-090919.backup\n"
        let date = CheckupParse.tmutilLatest(path)
        XCTAssertNotNil(date)
        XCTAssertEqual(date.map { Calendar.current.component(.hour, from: $0) }, 9)
        XCTAssertNil(CheckupParse.tmutilLatest("No machine directory found for host.\n"))
    }

    func testExtensions() {
        let sysext = """
        2 extension(s)
        --- com.apple.system_extension.driver_extension (Go to 'System Settings > General > Login Items & Extensions > Driver Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\t52444FG85C\tcom.silabs.cp210x (6.0.2/1)\tcom.silabs.cp210x\t[activated enabled]
        \t\tABCDE12345\tcom.example.filter (1.0/1)\tExample Filter\t[activated waiting for user]
        """
        let s = CheckupParse.systemExtensions(sysext)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].bundleID, "com.silabs.cp210x"); XCTAssertTrue(s[0].enabled && s[0].active)
        XCTAssertEqual(s[1].state, "activated waiting for user"); XCTAssertFalse(s[1].enabled)
        XCTAssertEqual(CheckupRules.systemExtensions(sysext).status, .attention)
        XCTAssertEqual(CheckupRules.systemExtensions("0 extension(s)\n").status, .pass)

        let kmutil = """
            3  207 0                  0          0          com.apple.kpi.bsd (27.2.0) 16356FD0-D093-34E9-B4CD-A22CA9B05142 <>
          150    0 0xfffffe0007a1c000 0x8000     0x8000     com.example.driver (1.2.3) 11111111-2222-3333-4444-555555555555 <6 5 3>
        """
        XCTAssertEqual(CheckupParse.thirdPartyKexts(kmutil), ["com.example.driver (1.2.3)"])
        XCTAssertEqual(CheckupRules.kexts(kmutil).status, .attention)
        XCTAssertEqual(CheckupRules.kexts(nil).status, .unknown)
    }

    func testBatteryAndOthers() throws {
        let json = """
        {"SPPowerDataType":[{"_name":"spbattery_information","sppower_battery_health_info":{"sppower_battery_cycle_count":887,
        "sppower_battery_health":"Service Recommended","sppower_battery_health_maximum_capacity":"72%"}}]}
        """
        let b = try XCTUnwrap(CheckupParse.battery(Data(json.utf8)))
        XCTAssertEqual(b.cycles, 887); XCTAssertEqual(b.maxCapacity, "72%")
        XCTAssertEqual(CheckupRules.battery(b, hasBattery: true).status, .attention)
        XCTAssertEqual(CheckupRules.battery(nil, hasBattery: false).status, .unknown)
        XCTAssertNil(CheckupParse.battery(Data(#"{"SPPowerDataType":[]}"#.utf8)))

        let now = Date()
        XCTAssertEqual(CheckupRules.uptime(boot: now.addingTimeInterval(-40 * 86_400), now: now).status, .attention)
        XCTAssertEqual(CheckupRules.uptime(boot: now.addingTimeInterval(-2 * 86_400), now: now).status, .pass)
        let vol = VolumeInfo(name: "Macintosh HD", path: "/", capacity: 500_000_000_000, available: 10_000_000_000, fileSystem: "APFS", isInternal: true)
        XCTAssertEqual(CheckupRules.freeSpace(vol).status, .attention)
        XCTAssertEqual(CheckupRules.freeSpace(nil).status, .unknown)
        XCTAssertEqual(CheckupRules.drives([]).status, .unknown)
        // swap growing from 0.5 GB to 3 GB over 10 hours
        let hist = [(now.addingTimeInterval(-36_000), 0.5e9), (now.addingTimeInterval(-60), 3e9)]
        XCTAssertEqual(CheckupRules.swap(current: 3e9, history: hist, ram: 32e9).status, .attention)
        XCTAssertEqual(CheckupRules.swap(current: 0, history: [], ram: 32e9).status, .pass)
        XCTAssertEqual(CheckupRules.swap(current: nil, history: [], ram: nil).status, .unknown)
        let crash = { (p: String) in DiagnosticReport(path: UUID().uuidString, kind: .crash, process: p, time: now, summary: nil) }
        XCTAssertEqual(CheckupRules.reports([crash("A")]).status, .pass)
        XCTAssertEqual(CheckupRules.reports([crash("A"), crash("A"), crash("A")]).status, .attention)
    }

    /// The whole checklist on this Mac: every check returns a row, and unknown rows always say why.
    func testLiveRun() {
        let r = Checkup.run(swapHistory: [])
        XCTAssertEqual(r.count, 17)
        for c in r where c.status == .unknown { XCTAssertFalse(c.detail.isEmpty, c.id) }
    }
}

final class PeripheralsTests: XCTestCase {
    func testSystemProfilerSections() throws {
        let json = """
        {"SPThunderboltDataType":[{"_name":"thunderboltusb4_bus_0","receptacle_1_tag":{"current_speed_key":"Up to 40 Gb/s","receptacle_id_key":"1",
           "receptacle_status_key":"receptacle_connected"},"_items":[{"_name":"Dock","device_name_key":"TB Dock","vendor_name_key":"Example Inc.",
           "_items":[{"device_name_key":"Drive","vendor_name_key":"Example Inc."}]}]}],
         "SPDisplaysDataType":[{"_name":"Apple M1 Max","sppci_model":"Apple M1 Max","spdisplays_ndrvs":[{"_name":"Color LCD","_spdisplays_displayID":"1",
           "_spdisplays_pixels":"3456 x 2234","_spdisplays_resolution":"1728 x 1117 @ 120.00Hz","spdisplays_connection_type":"spdisplays_internal",
           "spdisplays_main":"spdisplays_yes"}]}],
         "SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on"},
           "device_connected":[{"Buds":{"device_address":"00:11:22:33:44:55","device_minorType":"Headset","device_batteryLevelLeft":"70%",
             "device_batteryLevelRight":"75%","device_batteryLevelCase":"40%"}},{"Magic Mouse":{"device_address":"00:11:22:33:44:66","device_minorType":"Mouse"}}],
           "device_not_connected":[{"Speaker":{"device_address":"00:11:22:33:44:77"}}]}],
         "SPAudioDataType":[{"_name":"coreaudio_device","_items":[{"_name":"Speakers","coreaudio_default_audio_output_device":"spaudio_yes",
           "coreaudio_device_output":2,"coreaudio_device_srate":48000,"coreaudio_device_transport":"coreaudio_device_type_builtin"}]}],
         "SPPowerDataType":[{"_name":"sppower_ac_charger_information","sppower_ac_charger_name":"140W USB-C Power Adapter",
           "sppower_ac_charger_watts":"140","sppower_battery_charger_connected":"TRUE","sppower_battery_is_charging":"FALSE"}]}
        """
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let tb = Peripherals.parseThunderbolt(root)
        XCTAssertEqual(tb.first?.name, "Thunderbolt/USB4 bus 0")
        XCTAssertEqual(tb.first?.ports, ["Port 1 · Up to 40 Gb/s · Connected"])
        XCTAssertEqual(tb.first?.devices.count, 2)   // the daisy-chained drive is found too
        let d = try XCTUnwrap(Peripherals.parseDisplays(root).first)
        XCTAssertEqual(d.refreshHz, 120); XCTAssertEqual(d.resolution, "1728 x 1117"); XCTAssertEqual(d.displayID, 1)
        XCTAssertEqual(d.connection, "Internal"); XCTAssertTrue(d.isMain); XCTAssertNil(d.hdr)
        let parsed = Peripherals.parseBluetooth(root)
        var bt = parsed.0; let state = parsed.1
        XCTAssertEqual(state, "On"); XCTAssertEqual(bt.count, 3)
        XCTAssertEqual(bt.first { $0.name == "Buds" }?.battery, ["Left": 70, "Right": 75, "Case": 40])
        Peripherals.mergeHIDBatteries(&bt, ["Magic Mouse": 55, "Speaker": 10])
        XCTAssertEqual(bt.first { $0.name == "Magic Mouse" }?.battery, ["Main": 55])
        XCTAssertEqual(bt.first { $0.name == "Speaker" }?.battery, [:])   // not connected: no stale level
        let a = try XCTUnwrap(Peripherals.parseAudio(root).first)
        XCTAssertTrue(a.defaultOutput); XCTAssertEqual(a.sampleRate, 48000); XCTAssertEqual(a.transport, "Builtin")
        let p = try XCTUnwrap(Peripherals.parsePower(root))
        XCTAssertEqual(p.watts, 140); XCTAssertEqual(p.charging, false); XCTAssertEqual(p.connected, true)
    }

    func testUSB() {
        let hub = Peripherals.usbDevice(id: 1, parent: nil, props: ["kUSBProductString": "Hub", "USBSpeed": 4, "idVendor": 0x05ac])
        let kb = Peripherals.usbDevice(id: 2, parent: 1, props: ["USB Product Name": "Keyboard", "kUSBVendorString": "Example", "USBSpeed": 1,
                                                                  "UsbPowerSinkAllocation": 100, "UsbPowerSinkCapability": 500])
        XCTAssertEqual(hub.speed, "5 Gb/s (SuperSpeed)"); XCTAssertNil(hub.powerAllocatedmA)
        XCTAssertEqual(kb.name, "Keyboard"); XCTAssertEqual(kb.powerAllocatedmA, 100); XCTAssertEqual(kb.speed, "12 Mb/s (Full Speed)")
        let tree = Peripherals.usbTree([kb, hub])
        XCTAssertEqual(tree.map(\.device.id), [1, 2]); XCTAssertEqual(tree.map(\.depth), [0, 1])
    }

    /// Live: collect() must not crash and must keep the IOKit sections even if system_profiler fails.
    func testLiveCollect() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/system_profiler") else { throw XCTSkip("no system_profiler") }
        let r = Peripherals.collect()
        if r.profilerError == nil { XCTAssertFalse(r.displays.isEmpty && r.audio.isEmpty && r.thunderbolt.isEmpty, "system_profiler returned nothing usable") }
    }
}
