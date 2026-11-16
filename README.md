# Flightdeck

A native macOS task manager and system monitor (Swift, SwiftUI + AppKit). It answers "why is my Mac slow?"
by showing which process and which subsystem is responsible.

## Build & run

```sh
./scripts/bundle.sh          # universal (arm64 + x86_64) release → build/Flightdeck.app
open build/Flightdeck.app
swift test                   # core sampler tests
```

Requires macOS 14+, Xcode 16+ toolchain.

## Views

Summary · Performance (CPU per core with P/E colouring, overall/logical/cluster modes; Memory; Disk; Network with per-app traffic;
Energy; Thermals; GPU) · Processes (live tree, sort/filter, Quit/Force Quit/Suspend/Resume) · System Info ·
Startup Apps · Users · Services (launchd) · Power & Freq · Connections · Installed Apps · Disk Space · Benchmarks

**Flight Recorder:** Record (⇧⌘R) captures every telemetry frame and saves it as a `.flightlog` file
(zlib-compressed JSON). Open it (⌘O, or double-click in Finder) to scrub or replay it through the same views. Older `.mltrace` recordings from before the rename still open.

**Black box:** an always-on rolling recorder (on by default, Settings to turn off or clear). It keeps every sample
for the last hour and one sample every 10 s for 24 hours, capped at 50 MB, in
`~/Library/Application Support/Flightdeck/BlackBox` as ordinary `.flightlog` segments. Recorder › Save from Black Box
saves the last 5 minutes to 24 hours after the fact; Recorder › Replay Black Box (⇧⌘B: last 10 minutes) replays it.

Six themes: Light, Dark, Green, Amber, Blue, Mono.

**Live Dock icon:** right-click the Dock icon (or use Monitor › Dock Icon, or Settings) to pick a mode:
CPU History (scrolling graph), CPU Cores (one VFD column per core, coloured by P/E), System Gauges (CPU, memory
and temperature), or the static App Icon. It follows the current theme and shows a red tally light while the
Flight Recorder is recording. The static `AppIcon.icns` is rendered by the same code at build time
(`Flightdeck --render-iconset <dir>`); `--render-dock-previews <dir>` writes every mode × theme as a PNG.

## Measurement principles

- **No invented zeros.** Every value is `Measured<T>`, either `.value` or `.unavailable(reason)`. Unmeasured
  values show "—". Examples: other users' processes without root, the first sample before deltas exist,
  Macs without sensors.
- **Gaps, not interpolation.** Pausing or missed samples are stored as `nil` and drawn as line breaks, both live and in replay.
- **Self-monitoring.** Flightdeck appears in its own process list by default (Settings → toggle).
- **Identity-safe actions.** Signals are sent only if the PID still has the same start time (`ProcessIdentity`).
- **Private by design.** Flightdeck makes no network requests at all.

## Known limits

- Per-process network traffic comes from `/usr/bin/nettop`. Only that Apple binary holds the private
  network-statistics entitlement, so Flightdeck runs it once per sample (about 18 ms CPU) and diffs per-connection
  counters. A connection that opens and closes between two samples isn't counted. Against a 5 MB curl download
  the count came out at 5.01 MB (the extra is TLS overhead).
- Live CPU clock frequency needs private IOReport access, so it isn't shown. Power & Freq shows the DVFS tables instead.
- Connections lists only your own processes' sockets, since `lsof` runs without root.
- Thermal sensors refresh every 4 s, because reading all HID sensors costs about 70 ms.

## Layout

- `Sources/FlightdeckCore`: samplers (CPU, memory, disk, network, power/thermal, processes), providers
  (system info, launchd, connections, apps, disk usage, frequency, benchmarks), and `Snapshot`/`Trace`.
- `Sources/Flightdeck`: the SwiftUI app. `Engine` owns sampling, history and recording/replay. The process
  table is an AppKit `NSOutlineView` updated by diffing, for low overhead.

Automation hooks: `open build/Flightdeck.app --args -destination "Processes" -theme green -replayIndex 10`.
