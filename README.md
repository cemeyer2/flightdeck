# FlightDeck

A native macOS task manager and system monitor (Swift, SwiftUI + AppKit). It answers "why is my Mac slow?"
by showing which process and which subsystem is responsible.

## Build & run

```sh
./scripts/bundle.sh          # universal (arm64 + x86_64) release → build/FlightDeck.app
open build/FlightDeck.app
swift test                   # core sampler tests
```

Requires macOS 14+, Xcode 16+ toolchain.

**Distributing:** `./scripts/release.sh` builds `build/FlightDeck.dmg` (drag-to-Applications). With
`SIGN_ID="Developer ID Application: … (TEAMID)"` it signs with the hardened runtime (`scripts/FlightDeck.entitlements`);
add `NOTARY_PROFILE=<notarytool keychain profile>` to notarize and staple, so it opens on any Mac without Gatekeeper
warnings. Without them the app is ad-hoc signed, which is fine for your own Mac. Open at login works best from
/Applications.

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

**Annunciator panel:** across the top of Summary, a cockpit-style grid of labelled lights (CPU, MEM, SWAP, THERM,
DISK, STORAGE, NET, GPU, POWER, HANG, CRASH, AWAKE), each lit amber or red by the worst current finding in that
subsystem. Hover to see why; click to jump to the cause.

**Diagnosis and Flight Log:** an analyzer turns the sample stream into plain-English findings on the Summary banner
(click one to jump to where to look). It smooths over spikes and groups helper processes into their app. It detects
apps hogging CPU, memory pressure and growing swap, apps whose memory grows steadily (likely leaks), thermal throttling (and explains kernel_task), measured CPU throttling (busy performance cores held well below their top clock while hot), heavy disk or network I/O, frequent wake-ups, a startup disk that will fill up within days,
and anything unusual for *this* Mac, compared with a baseline built from the black box's 24 hours. Well-known
background work (Spotlight, Time Machine, iCloud, Photos analysis, updates) is explained. Anything lasting 20 s or
more goes into the **Flight Log** (kept 7 days) with a one-click replay of that moment from the black box. A **timeline** (1/6/24 h) of CPU, memory pressure and temperature with incident markers sits on top; click any moment to replay it. The Flight Log also lists **macOS reports** from the last 7 days (crashes with exception type, hangs, memory kills, CPU and disk-write limit violations), and an app that crashes or hangs repeatedly becomes a finding. When an app hangs or hogs the CPU or GPU, FlightDeck **captures its call stacks automatically** (3 s with `/usr/bin/sample`, at most one per problem every 10 minutes) and attaches them to the incident with a one-line summary such as "Main thread waiting in __psynch_mutexwait ← -[Model sortItems:]" (Settings to turn off; kept 7 days). Right-click a finding to inspect the responsible process, quit its app, or mute its alerts.

**Master caution:** a menu bar instrument strip (caution light, CPU and memory bars; or CPU % or the light alone)
opens a panel with the caution status, gauges, findings, top apps and quick actions. With it on, closing the window
keeps FlightDeck running, so the black box and alerts continue (Settings › Open at login). Sustained cautions and
warnings also post a notification (after 2 minutes by default, once per occurrence, at most every 30 minutes per
problem; click to jump to the right view), and light an amber or red caution lamp on the Dock icon.

**Process inspector:** double-click a process (or ⌘I, or Inspect… in its menu) to open it in its own window:
CPU, memory, disk and network history (every process's last 300 samples are kept, not just the busiest), PID,
parent and children, user, start time, CPU time, energy, wake-ups, arguments, working directory, code signature
(Apple, Developer ID, ad-hoc or invalid; team; hardened runtime), kernel statistics with rates (page faults, page-ins, Unix and Mach syscalls, context switches, Mach messages, resident/virtual and peak memory, instructions per cycle, logical writes), every open file descriptor, sockets with addresses
and TCP state, threads (CPU, state, priority, times), the environment, and call-stack sampling via
`/usr/bin/sample` to see why it's busy or hung. Actions: quit, force quit, suspend, resume, lower priority (nice).
Anything macOS doesn't let a normal user read for other users' processes is shown as unavailable.

**Connection quality** (Performance › Network): Wi-Fi signal, noise, SNR, link rate, channel, band, width, PHY and
security from CoreWLAN, plus router and DNS servers, all local. An opt-in probe (off by default) pings the router and
an internet host every 10 s, so FlightDeck can tell "your Wi-Fi is the problem" from "your internet provider is".

**Processes** can be shown as a parent/child **Tree**, grouped by **Apps** (every helper rolled into its app, with
app-level Quit / Force Quit), or **Flat**. The filter understands queries: `cpu>50 mem>1g user:root app:chrome kind:intel gpu>0 wakeups>500 sleep hung` (terms combine; plain text matches name, path, user or PID). Right-click the column header to choose columns; layout persists. ⌘1–⌘9 jump between sections (Go menu). The **Kind** column shows Apple-silicon or Intel (Rosetta) binaries, and **Sleep** shows who is keeping the Mac or display awake (also a finding, with the reason the app gave). Apps the window server considers hung are marked **Not Responding** in red
and raise a warning finding.

**Energy and storage health:** Performance › Energy has an **energy budget**: which apps used the most energy
(Wh and average W) over the last 1, 8 or 24 hours, how long the Mac ran on battery and how much charge that took,
and a battery charge history, all from the black box. Battery health uses the same capacity figure as macOS
(nominal ÷ design). Performance › Disk shows **drive health** from the SSD's NVMe SMART log (wear, spare,
lifetime reads and writes, power-on hours, unsafe shutdowns, media errors) and how many days until the startup
disk fills at the current rate. Unhealthy drives raise a warning.

**Thermals** adds fan speeds from the SMC (RPM, min, max, target, history) and a sensor heatmap of every
temperature sensor, hottest first.

**GPU** (Performance › GPU): utilisation (device, renderer, tiler), active residency, live average clock and a
per-P-state histogram, GPU power, GPU memory in use against Metal's recommended working set, driver
**recoveries** (GPU hangs that macOS reset), thermal clock capping, per-app GPU share and total GPU time (also a
GPU % column in Processes and a graph in the inspector), live CPU cluster clocks, and Metal and display details.
The data comes from the accelerator's statistics and IOReport, readable without root. Energy channels macOS hides
from normal users (CPU, ANE, DRAM) are shown as unavailable, not 0. Findings cover GPU hangs, thermal capping,
GPU memory near its limit, and apps hogging the GPU.

**Export:** Recorder › Export writes a one-page **PDF flight report** (findings, average/95th/peak statistics,
top apps, graphs) or **CSV** (system metrics, or per-process) for the replayed recording, or the last hour of the
black box when live. Unmeasured values are empty CSV cells, not zeros.

**Compare recordings** (Recorder › Compare Recordings…): two `.flightlog` files side by side, for example before
and after an update. Shows average and 95th-percentile statistics with the change in each, overlaid graphs aligned by
elapsed time, and which apps' CPU use changed.

**Command line:** the app binary doubles as a CLI
(`alias flightdeck=/Applications/FlightDeck.app/Contents/MacOS/FlightDeck`):

```sh
flightdeck --snapshot [--top N]     # summary, top apps and findings after a 1 s warm-up
flightdeck --snapshot --json        # full snapshot + findings as JSON (for scripts and Shortcuts)
flightdeck --findings               # what's wrong right now
flightdeck --stats rec.flightlog    # statistics and findings of a recording
flightdeck --csv rec.flightlog out.csv [--processes]
flightdeck --report rec.flightlog out.pdf
flightdeck --render-views <dir>     # write 2x PNGs of the main views with live data (visual review, no window)
flightdeck --bench-ui [N]           # render every main view off-screen N times with live data; ms per frame
```

Six themes: Light, Dark, Green, Amber, Blue, Mono.

**Live Dock icon:** right-click the Dock icon (or use Monitor › Dock Icon, or Settings) to pick a mode:
CPU History (scrolling graph), CPU Cores (one VFD column per core, coloured by P/E), System Gauges (CPU, memory
and temperature), or the static App Icon. It follows the current theme and shows a red tally light while the
Flight Recorder is recording. The static `AppIcon.icns` is rendered by the same code at build time
(`FlightDeck --render-iconset <dir>`); `--render-dock-previews <dir>` writes every mode × theme as a PNG.

**Startup Apps** shows who signed every launch agent, daemon and login item, flags unsigned ones, and marks items
whose program no longer exists (leftovers from removed apps), with a summary at the top.

**Sleep & Wake** reads the power-management log (no root): every sleep session with why it slept, what woke it,
each dark wake (screen-off wakes for network upkeep, Power Nap, Bluetooth) in plain English, battery used overnight,
which processes scheduled wakes, and which apps kept the Mac awake and for how long.

**Rules** automate responses: "when app *Chrome* has CPU % above 300 for 10 minutes, notify me / lower its priority /
suspend / quit / force quit / run a command". Commands get `FD_RULE`, `FD_SUBJECT`, `FD_PIDS`, `FD_METRIC` and `FD_VALUE`
in their environment (names are never spliced into the shell). Rules fire once per occurrence with a cooldown, signals
are identity-checked, and every action posts a notification and lands in the Flight Log and a saved action log.
Safety rails: quit/suspend/renice never touch macOS components (anything under /System, /usr, /bin, /sbin), Finder, Dock,
terminals, the app you're using, or FlightDeck itself; app rules quit through the app (so it can ask to save);
destructive rules always wait at least a minute, and a match-everything destructive rule must be explicitly confirmed;
suspended apps resume automatically (and when FlightDeck quits); commands time out after 60 s with their output logged.
"Test Against the Last 24 Hours" dry-runs a rule on the black box before you save it.

## Measurement principles

- **No invented zeros.** Every value is `Measured<T>`, either `.value` or `.unavailable(reason)`. Unmeasured
  values show "—". Examples: other users' processes without root, the first sample before deltas exist,
  Macs without sensors.
- **Gaps, not interpolation.** Pausing or missed samples are stored as `nil` and drawn as line breaks, both live and in replay.
- **Light in the background.** With no FlightDeck window on screen, view updates stop (graphs catch up instantly when you return) and sampling drops to every 2 s (Settings); the black box, findings and alerts keep running. Background cost is about 2.5% of one core.
- **Self-monitoring.** FlightDeck appears in its own process list by default (Settings → toggle).
- **Identity-safe actions.** Signals are sent only if the PID still has the same start time (`ProcessIdentity`).
- **Private by design.** FlightDeck sends no data anywhere. By default it makes no network requests at all; the only exception is the opt-in latency probe (Settings › Network quality), which pings your router and one host you choose.

## Known limits

- Per-process network traffic comes from `/usr/bin/nettop`. Only that Apple binary holds the private
  network-statistics entitlement, so FlightDeck runs it once per sample (about 18 ms CPU) and diffs per-connection
  counters. A connection that opens and closes between two samples isn't counted. Against a 5 MB curl download
  the count came out at 5.01 MB (the extra is TLS overhead).
- Live CPU clock frequency needs private IOReport access, so it isn't shown. Power & Freq shows the DVFS tables instead.
- Connections lists only your own processes' sockets, since `lsof` runs without root.
- Thermal sensors refresh every 4 s, because reading all HID sensors costs about 70 ms.

## Layout

- `Sources/FlightDeckCore`: samplers (CPU, memory, disk, network, power/thermal, processes), providers
  (system info, launchd, connections, apps, disk usage, frequency, benchmarks), and `Snapshot`/`Trace`.
- `Sources/FlightDeck`: the SwiftUI app. `Engine` owns sampling, history and recording/replay. The process
  table is an AppKit `NSOutlineView` updated by diffing, for low overhead.

Automation hooks: `open build/FlightDeck.app --args -destination "Processes" -theme green -replayIndex 10`.
