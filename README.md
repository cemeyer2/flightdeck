# Meterline

A native macOS task manager and system monitor (Swift, SwiftUI + AppKit). It answers "why is my Mac slow?"
by showing which process and which subsystem is responsible.

## Build & run

```sh
./scripts/bundle.sh          # universal (arm64 + x86_64) release → build/Meterline.app
open build/Meterline.app
swift test                   # core sampler tests
```

Requires macOS 14+, Xcode 16+ toolchain.

## Views

Summary · Performance (CPU per core with P/E colouring, overall/logical/cluster modes; Memory; Disk; Network;
Energy; Thermals; GPU) · Processes (live tree, sort/filter, Quit/Force Quit/Suspend/Resume) · System Info ·
Startup Apps · Users · Services (launchd) · Power & Freq · Connections · Installed Apps · Disk Space · Benchmarks

**Flight Recorder:** Record (⇧⌘R) captures every telemetry frame and saves it as a `.mltrace` file
(zlib-compressed JSON). Open it (⌘O, or double-click in Finder) to scrub or replay it through the same views.

Six themes: Light, Dark, Green, Amber, Blue, Mono.

## Measurement principles

- **No invented zeros.** Every value is `Measured<T>`, either `.value` or `.unavailable(reason)`. Unmeasured
  values show "—". Examples: other users' processes without root, the first sample before deltas exist,
  Macs without sensors.
- **Gaps, not interpolation.** Pausing or missed samples are stored as `nil` and drawn as line breaks, both live and in replay.
- **Self-monitoring.** Meterline appears in its own process list by default (Settings → toggle).
- **Identity-safe actions.** Signals are sent only if the PID still has the same start time (`ProcessIdentity`).
- **Private by design.** Meterline makes no network requests at all.

## Known limits

- Per-process network bytes and live CPU clock frequency need private or root-only interfaces, so they aren't
  shown. Power & Freq shows the DVFS frequency tables instead.
- Connections lists only your own processes' sockets, since `lsof` runs without root.
- Thermal sensors refresh every 4 s, because reading all HID sensors costs about 70 ms.

## Layout

- `Sources/MeterCore`: samplers (CPU, memory, disk, network, power/thermal, processes), providers
  (system info, launchd, connections, apps, disk usage, frequency, benchmarks), and `Snapshot`/`Trace`.
- `Sources/Meterline`: the SwiftUI app. `Engine` owns sampling, history and recording/replay. The process
  table is an AppKit `NSOutlineView` updated by diffing, for low overhead.

Automation hooks: `open build/Meterline.app --args -destination "Processes" -theme green -replayIndex 10`.
