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

**Diagnosis and Flight Log:** an analyzer turns the sample stream into plain-English findings on the Summary banner
(click one to jump to where to look). It smooths over spikes and groups helper processes into their app. It detects
apps hogging CPU, memory pressure and growing swap, apps whose memory grows steadily (likely leaks), thermal throttling
(and explains kernel_task), heavy disk or network I/O, frequent wake-ups, a startup disk that will fill up within days,
and anything unusual for *this* Mac, compared with a baseline built from the black box's 24 hours. Well-known
background work (Spotlight, Time Machine, iCloud, Photos analysis, updates) is explained. Anything lasting 20 s or
more goes into the **Flight Log** (kept 7 days) with a one-click replay of that moment from the black box.

**Master caution:** a menu bar instrument strip (caution light, CPU and memory bars; or CPU % or the light alone)
opens a panel with the caution status, gauges, findings, top apps and quick actions. With it on, closing the window
keeps Flightdeck running, so the black box and alerts continue (Settings › Open at login). Sustained cautions and
warnings also post a notification (after 2 minutes by default, once per occurrence, at most every 30 minutes per
problem; click to jump to the right view), and light an amber or red caution lamp on the Dock icon.

**Process inspector:** double-click a process (or ⌘I, or Inspect… in its menu) to open it in its own window:
CPU, memory, disk and network history (every process's last 300 samples are kept, not just the busiest), PID,
parent and children, user, start time, CPU time, energy, wake-ups, arguments, working directory, code signature
(Apple, Developer ID, ad-hoc or invalid; team; hardened runtime), every open file descriptor, sockets with addresses
and TCP state, threads (CPU, state, priority, times), the environment, and call-stack sampling via
`/usr/bin/sample` to see why it's busy or hung. Actions: quit, force quit, suspend, resume, lower priority (nice).
Anything macOS doesn't let a normal user read for other users' processes is shown as unavailable.

**Connection quality** (Performance › Network): Wi-Fi signal, noise, SNR, link rate, channel, band, width, PHY and
security from CoreWLAN, plus router and DNS servers, all local. An opt-in probe (off by default) pings the router and
an internet host every 10 s, so Flightdeck can tell "your Wi-Fi is the problem" from "your internet provider is".

**Processes** can be shown as a parent/child **Tree**, grouped by **Apps** (every helper rolled into its app, with
app-level Quit / Force Quit), or **Flat**. Apps the window server considers hung are marked **Not Responding** in red
and raise a warning finding.

**Energy and storage health:** Performance › Energy has an **energy budget**: which apps used the most energy
(Wh and average W) over the last 1, 8 or 24 hours, how long the Mac ran on battery and how much charge that took,
and a battery charge history, all from the black box. Battery health uses the same capacity figure as macOS
(nominal ÷ design). Performance › Disk shows **drive health** from the SSD's NVMe SMART log (wear, spare,
lifetime reads and writes, power-on hours, unsafe shutdowns, media errors) and how many days until the startup
disk fills at the current rate. Unhealthy drives raise a warning.

**Thermals** adds fan speeds from the SMC (RPM, min, max, target, history) and a sensor heatmap of every
temperature sensor, hottest first.

**Export:** Recorder › Export writes a one-page **PDF flight report** (findings, average/95th/peak statistics,
top apps, graphs) or **CSV** (system metrics, or per-process) for the replayed recording, or the last hour of the
black box when live. Unmeasured values are empty CSV cells, not zeros.

**Command line:** the app binary doubles as a CLI
(`alias flightdeck=/Applications/Flightdeck.app/Contents/MacOS/Flightdeck`):

```sh
flightdeck --snapshot [--top N]     # summary, top apps and findings after a 1 s warm-up
flightdeck --snapshot --json        # full snapshot + findings as JSON (for scripts and Shortcuts)
flightdeck --findings               # what's wrong right now
flightdeck --stats rec.flightlog    # statistics and findings of a recording
flightdeck --csv rec.flightlog out.csv [--processes]
flightdeck --report rec.flightlog out.pdf
```

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
- **Private by design.** Flightdeck sends no data anywhere. By default it makes no network requests at all; the only exception is the opt-in latency probe (Settings › Network quality), which pings your router and one host you choose.

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
