# FlightDeck

A native macOS task manager and system monitor (Swift, SwiftUI + AppKit). It answers "why is my Mac slow?"
by showing which process and which subsystem is responsible.

## Contents

- [Screenshots](#screenshots)
- [Build & run](#build--run)
- [Pages](#pages)
  - [Overview](#overview)
    - [Drill down from Summary](#drill-down-from-summary)
    - [Customizable cockpit](#customizable-cockpit)
    - [Annunciator panel](#annunciator-panel)
    - [Ambient mode](#ambient-mode)
    - [Stress Map](#stress-map)
    - [Diagnosis and Flight Log](#diagnosis-and-flight-log)
    - [Trends](#trends)
    - [Weekly Report](#weekly-report)
    - [Checkup](#checkup)
    - [Restarts & Crashes](#restarts--crashes)
    - [Boot and login time](#boot-and-login-time)
    - [What Changed](#what-changed)
  - [Activity](#activity)
    - [Performance](#performance)
    - [Processes](#processes)
    - [Process inspector](#process-inspector)
    - [Connection quality](#connection-quality)
    - [Energy and storage health](#energy-and-storage-health)
    - [Charging insights](#charging-insights)
    - [Battery health forecast](#battery-health-forecast)
    - [Why is the fan loud?](#why-is-the-fan-loud)
    - [Thermals](#thermals)
    - [GPU](#gpu)
    - [Launches](#launches)
    - [Console](#console)
    - [Camera & Mic](#camera--mic)
  - [Power](#power)
    - [Power & Freq](#power--freq)
    - [Sleep & Wake](#sleep--wake)
  - [Network](#network)
    - [Network map](#network-map)
    - [Wi-Fi](#wi-fi)
    - [Internet](#internet)
    - [Destinations](#destinations)
    - [Connections](#connections)
    - [UPnP](#upnp)
    - [UniFi](#unifi)
    - [Fleet](#fleet)
  - [Storage](#storage)
    - [Disk Space › Folder Scanner](#disk-space--folder-scanner)
    - [Disk Space › What's Using My Disk](#disk-space--whats-using-my-disk)
    - [Backups](#backups)
  - [System](#system)
    - [System Info](#system-info)
    - [Installed Apps](#installed-apps)
    - [Startup Apps](#startup-apps)
    - [Peripherals](#peripherals)
    - [Displays](#displays)
    - [Services](#services)
    - [Users](#users)
  - [Tools](#tools)
    - [Rules](#rules)
    - [Developer](#developer)
    - [Benchmarks](#benchmarks)
- [Recording and replay](#recording-and-replay)
- [Everywhere in the app](#everywhere-in-the-app)
- [Integrations](#integrations)
- [Measurement principles](#measurement-principles)
- [Known limits](#known-limits)
- [Layout](#layout)

## Screenshots

These are taken in demo mode, which feeds the real UI invented data (a busy "Demo Mac" on an invented network), so nothing here describes a real machine.

| | |
|---|---|
| ![Summary](docs/screenshots/summary.jpg) **Summary:** a customisable cockpit of instruments; click any one for its detailed view | ![Stress Map](docs/screenshots/stress-map.jpg) **Stress Map:** which apps are straining which parts of the Mac, animated between samples |
| ![Flight Log](docs/screenshots/flight-log.jpg) **Flight Log:** a 24 h timeline, past incidents with stack evidence, and macOS crash/hang reports | ![Trends](docs/screenshots/trends.jpg) **Trends:** 90 days of daily history, with before/after comparisons around updates |
| ![Processes](docs/screenshots/processes.jpg) **Processes:** grouped by app, with GPU, disk, network and energy per process | ![Camera & Mic](docs/screenshots/camera-mic.jpg) **Camera & Mic:** which app used the camera or microphone, and when |
| ![Performance › CPU](docs/screenshots/cpu.jpg) **Performance › CPU:** per-cluster load and clocks, coloured by performance/efficiency core | ![Performance › Thermals](docs/screenshots/thermals.jpg) **Performance › Thermals:** every sensor by component, throttling, fan health and "why is the fan loud?" |
| ![Performance › Energy](docs/screenshots/charging.jpg) **Performance › Energy:** what the charger negotiated and where the power goes | ![Sleep & Wake](docs/screenshots/sleep-wake.jpg) **Sleep & Wake:** dark wakes, overnight drain, and who kept the Mac awake |
| ![Network](docs/screenshots/network.jpg) **Network:** the devices on the local network, from this Mac to the internet | ![Wi-Fi](docs/screenshots/wifi.jpg) **Wi-Fi:** your link over time, roams, channel congestion and a channel suggestion |
| ![Restarts & Crashes](docs/screenshots/restarts.jpg) **Restarts & Crashes:** how each session ended, kernel panics explained, and boot and login time | ![Destinations](docs/screenshots/destinations.jpg) **Destinations:** which hosts each app talks to, with new and unusual ones flagged |
| ![Internet](docs/screenshots/internet.jpg) **Internet:** speed and responsiveness tests explained, and data usage per app | ![UPnP](docs/screenshots/upnp.jpg) **UPnP:** UPnP devices and the port mappings apps opened on the router |
| ![UniFi](docs/screenshots/unifi.jpg) **UniFi:** a UniFi console's real topology: which AP or switch port each client is on | ![Disk Space](docs/screenshots/disk-space.jpg) **Disk Space:** what is using the disk, "System Data" explained, and safe cleanups |
| ![What Changed](docs/screenshots/changes.jpg) **What Changed:** new launch agents, extensions, profiles and apps, with the odd ones flagged | ![Weekly Report](docs/screenshots/weekly-report.jpg) **Weekly Report:** how the week went, compared with the one before, as a page or a PDF |
| ![Backups](docs/screenshots/backups.jpg) **Backups:** Time Machine runs, failures explained, gaps and backup disk space | ![Fleet](docs/screenshots/fleet.jpg) **Fleet:** your other Macs' vital signs and incidents, paired and read-only |
| ![Displays](docs/screenshots/displays.jpg) **Displays:** modes, ProMotion, HDR and the video link, with why it's stuck at 30 Hz | ![Peripherals](docs/screenshots/peripherals.jpg) **Peripherals:** link speeds with what's slowing a drive down, and accessory batteries |
| ![Developer](docs/screenshots/developer.jpg) **Developer:** dev servers, containers, Homebrew services, builds and toolchains | ![Rules](docs/screenshots/rules.jpg) **Rules:** automatic responses to sustained problems |
| ![Cockpit editing](docs/screenshots/cockpit-edit.jpg) **Cockpit editing:** add, remove, reorder and resize instruments; save layouts | ![Ambient mode](docs/screenshots/ambient.jpg) **Ambient mode:** a dim full-screen instrument panel for a second display |

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

**Releases:** pushing a version tag (`git tag v1.2.3 && git push origin v1.2.3`) runs `.github/workflows/release.yml`,
which tests, builds the DMG and a zip (version taken from the tag), and publishes them with SHA-256 sums as a GitHub
Release. It signs and notarizes when the Developer ID secrets listed at the top of that workflow are set; otherwise the
build is ad-hoc signed and the release notes explain how to open it past Gatekeeper.

## Pages

The sidebar groups the pages as below (sections fold away; ⌘1–⌘9 jump to the first nine). Every page also has a
demo-data version for screenshots (see Demo mode at the end).

- **Overview:** Summary (the cockpit) · Stress Map · Flight Log · Trends · Weekly Report · Checkup · Restarts & Crashes · What Changed
- **Activity:** Performance (CPU, Memory, Disk, Network, Energy, Thermals, GPU) · Processes · Launches · Console · Camera & Mic
- **Power:** Power & Freq · Sleep & Wake
- **Network:** Network · Wi-Fi · Internet · Destinations · Connections · UPnP · UniFi · Fleet
- **Storage:** Disk Space · Backups
- **System:** System Info · Peripherals · Displays · Installed Apps · Startup Apps · Services · Users
- **Tools:** Rules · Developer · Benchmarks

### Overview

Is my Mac OK, now and over time?

#### Drill down from Summary

Click any instrument (a "›" in its corner, a pointing-hand cursor and a tooltip show where it goes) to open the detailed view behind it: CPU and CPU Cores open Performance › CPU; Memory, Memory Pressure and Swap open Performance › Memory; Disk, Network, GPU, Energy, Battery & Charge and Battery Health, and Thermals and Fans open their Performance tabs; Wi-Fi Signal opens Wi-Fi; Destinations, Camera & Mic open their pages; Restarts and Boot Time open Restarts & Crashes; Top Processes opens Processes; the mini Stress Map opens the Stress Map. The annunciator lights and each finding already open their own causes.

#### Customizable cockpit

The Summary page is a grid of instruments you can arrange. Click **Edit** (⌥⌘E) to get a
strip above each instrument with a drag handle, a size control (S = one column, M = two, L = the whole row), move
buttons and a remove (×) button, plus an "Add instrument" palette. Drag instruments onto each other to reorder them;
**Done** leaves edit mode. Besides the classic Summary cards (annunciator, findings, CPU, Memory, Disk, Network, Energy,
Thermals, GPU, Top Processes) there are CPU Cores (a per-core strip, or per-core tiles when large), Memory Pressure,
Swap, Fans, Battery & Charge, Wi-Fi Signal, a static mini Stress Map, and Clock & Uptime. Five more digest the
pages added in 1.5, each a gauge card that also works as an Ambient gauge:

- **Destinations:** destinations new in the last 24 hours, the newest one named, and an amber "unusual traffic" line
  when a destination carries several times its usual daily bytes; graph: first contacts per day, last 14 days.
- **Restarts:** uptime, how the last session ended (clean, unexpected, kernel panic or not recorded; amber/red when not
  clean) and days since the last unexpected shutdown; graph: session lengths of the last 20 boots.
- **Boot Time:** this boot's boot → desktop time against the median of FlightDeck's saved earlier boots ("typical 25 s
  · 35 s slower", amber when much slower); graph: the last 12 measured boots with the typical line.
- **Battery Health:** health %, cycles (of the design count) and the month the trend reaches 80% (or "not enough
  data", "not declining", "reached"); graph: daily health readings.
- **Camera & Mic:** what is using the camera or microphone now (amber), or the last use and how long ago; graph:
  minutes in use per hour over the last day.

They read what the pages' models already keep and never read the disk or the log while drawing: Destinations
rebuilds its report off the main thread at most every 5 minutes while shown, Battery Health rebuilds from the
daily log's in-memory battery days every 30 minutes while shown, Restarts and Boot Time reuse the launch check's
collection (about 30 s after launch, so until then they show uptime and "reading the boot history"), and Camera &
Mic follows the camera/mic watch's own change events. In demo mode they show the pages' invented data. Wi-Fi had an
instrument already (Wi-Fi Signal: RSSI, SNR, link rate, band); channel congestion needs a scan, which briefly takes
the radio off its channel, so it stays on the Wi-Fi page. Layouts are named and saved
as JSON in user defaults (`cockpitLayouts`); the layout menu switches between them (Default, Thermals, Network,
Ambient, plus your own via Duplicate Layout) and resets one or all of them. Nothing is saved until you edit, and the
Default layout is the classic Summary page, so the page looks the same until you change it.

#### Annunciator panel

Across the top of Summary, a cockpit-style grid of labelled lights (CPU, MEM, SWAP, THERM,
DISK, STORAGE, NET, GPU, POWER, HANG, CRASH, AWAKE), each lit amber or red by the worst current finding in that
subsystem. CRASH also lights for an unexpected shutdown or kernel panic found by Restarts & Crashes. Hover to see why; click to jump to the cause.

#### Ambient mode

View › Ambient Mode (⌃⌘A), or the Ambient menu on Summary, opens a separate full-screen instrument
panel, meant for a second display or an iPad via Sidecar (View › Ambient Mode on Display picks the screen; the last one
used is remembered). It shows a big clock and uptime, the master caution light (lit with a steady glow while an
unmuted caution or warning is active), large gauges for the gauge-type instruments of the Ambient layout (or another
layout chosen under "Gauges From"), and a findings ticker that steps to the next finding every 8 s. It's dim by
default (right-click for brightness), the pointer hides when it rests, and Esc exits. To avoid burn-in the whole
panel moves by one point a minute around a 12-point square. Like the cockpit it redraws only once per sample (plus a
once-a-minute tick for the clock), with no continuous animation.

#### Stress Map

A graphical answer to "what is making my Mac miserable?". Subsystems (CPU, GPU, Thermal, Energy,
Network, Disk, Memory) are hubs around a ring, coloured by how strained each one is; apps are bubbles sized by how much
misery they cause and pulled toward the hubs they strain, with routes whose width shows how much they add there.
Hover for an app's breakdown, click to inspect it. Misery = the app's share of a resource × how strained that resource
is (power draw counts fully only on battery); unmeasured readings blame nobody. Works in replay too. Changes animate:
bubbles glide to each new sample's position, routes and hub gauges ease to their new strength, and traffic flows along
the routes toward the hubs. It's drawn with Core Animation, so the motion runs in macOS's render server and costs about
the same CPU as a static map. Settings › General › "Animate the Stress Map" (or macOS's Reduce Motion) turns it off.

#### Diagnosis and Flight Log

An analyzer turns the sample stream into plain-English findings on the Summary banner
(click one to jump to where to look). It smooths over spikes and groups helper processes into their app. It detects
apps hogging CPU, memory pressure and growing swap, apps whose memory grows steadily (likely leaks), thermal throttling (and explains kernel_task), measured CPU throttling (busy performance cores held well below their top clock while hot), heavy disk or network I/O, frequent wake-ups, a startup disk that will fill up within days,
and anything unusual for *this* Mac, compared with a baseline built from the black box's 24 hours. Well-known
background work (Spotlight, Time Machine, iCloud, Photos analysis, updates) is explained. Anything lasting 20 s or
more goes into the **Flight Log** (kept 7 days) with a one-click replay of that moment from the black box. A **timeline** (1/6/24 h) of CPU, memory pressure and temperature with incident markers sits on top; click any moment to replay it. The Flight Log also lists **macOS reports** from the last 7 days (crashes with exception type, hangs, memory kills, CPU and disk-write limit violations), and an app that crashes or hangs repeatedly becomes a finding. When an app hangs or hogs the CPU or GPU, FlightDeck **captures its call stacks automatically** (3 s with `/usr/bin/sample`, at most one per problem every 10 minutes) and attaches them to the incident with a one-line summary such as "Main thread waiting in __psynch_mutexwait ← -[Model sortItems:]" (Settings to turn off; kept 7 days). Muting (right-click a finding) can target one finding or a whole kind (e.g. every not-responding alert); muted findings don't notify or light the caution lights and are listed as muted in the banner. Right-click a finding to inspect the responsible process, quit its app, or mute its alerts.

#### Trends

Trends keeps one compact record per day for 90 days (`~/Library/Application Support/Flightdeck/daily-log.json`),
folded from the samples FlightDeck already takes: average and 95th-percentile CPU, memory pressure, peak swap, energy,
hottest sensor, sleep, crashes, hangs and incidents, macOS version, battery health and cycles, and the top ~30 apps' CPU
time, energy, peak memory and version. Charts cover 7, 30 or 90 days, with markers on days macOS or an app changed
version; pick an update for a **before/after** comparison in plain English ("Since Safari 26.2: energy +44%, 2 hangs
vs 0"). After 5 days it learns what is **normal for this Mac** per app and raises a finding when an app stays far above
it for 10 minutes ("Safari is using 3× its usual memory (usually ~1.8 GB)"). Performance › Energy and Trends show
**where this charge went**: each app's share of the energy since the Mac was unplugged. Days FlightDeck didn't run are
gaps, never zeros.

#### Weekly Report

A once-a-week digest of how this Mac did, for calendar weeks (Monday to Sunday, local time), built only from data
FlightDeck already keeps: the daily log, the Flight Log, boot and panic records, app freezes, battery history,
destinations and the startup disk. A headline ("A calm week", "A rough week: 1 kernel panic") sits over short sections,
each line carrying its numbers and a link to the page with the details: **what slowed the Mac down** (hours of high CPU,
memory pressure and heat from the Flight Log, the top incidents and the apps behind them, the busiest apps by CPU time,
the hottest sensor), **restarts, panics and freezes**, **battery** (cycles used, health change, how the 80% forecast
moved), **storage** (use, growth since the previous week's reading, days until full when free space is clearly
shrinking), **network** (internet data counted, new destinations worth a look; browsers are left out) and **compared
with the week before**. Sections without data are left out. A picker reaches every earlier week. Each week is saved as
a small JSON file in `~/Library/Application Support/Flightdeck/Reports/`, rebuilt at most once a day (and when the page
opens) until the week ends, so it stays readable after the raw data ages out; days whose incidents had already left the
7-day Flight Log are flagged. **Save as PDF…** paginates the report onto US Letter pages; **Copy as Text** copies it as
Markdown. Settings › Alerts › Weekly Report adds an opt-in notification (off by default; Monday 9:00 unless changed)
that summarizes the week just ended and opens the page; if the Mac was asleep or FlightDeck wasn't running, it arrives
at the next wake or launch.

#### Checkup

Checkup is a one-page health and security checklist: SIP, FileVault, Gatekeeper, firewall, Startup Security,
automatic and pending updates (the network check runs only when you press Check Now), Time Machine, free space, drive
and battery health, crashes and hangs this week, uptime, swap trend, login and background items, third-party kernel and
system extensions. Each row is OK, needs attention or unknown (with the reason), and links to the setting that fixes it.

#### Restarts & Crashes

Why the Mac restarted, froze or shut down, in plain English with what to do. Every boot is listed (and drawn on a
timeline) with how the session before it ended: **clean**, **unexpected**, **kernel panic** or **unknown**, then
grouped by cause. Each verdict names its evidence, strongest first, all readable without root:

- a **kernel panic report** for that session (`/Library/Logs/DiagnosticReports`, and its `Retired` folder): the old
  `.panic` text and the newer `.ips` JSON (bug type 210). FlightDeck pulls out the panic message, the panicked task
  and the kernel extensions in the backtrace, and names the likely culprit: "Kernel panic in com.example.driver: a
  third-party driver crashed the system; update or remove it", "WindowServer stopped responding, so the watchdog
  restarted the Mac", a whole-system hang ("no checkins from watchdogd"), sleep/wake, hardware, memory or graphics;
- the kernel's **shutdown cause code** ("Previous shutdown cause: −3"), read from the unified log with a query a few
  minutes wide around each boot (about a second each). The codes are explained (5 normal, 3 forced, 0 power lost,
  −3/−71/−74 overheating, −60 disk, −61/−62 watchdog, −128 power button…). Apple documents none of them, so each says
  whether its meaning is widely reported or only reported, and any other code is shown as "undocumented", never
  guessed;
- an **orderly-shutdown marker**: logd writes "All buffers flushed" to `/var/db/diagnostics/shutdown.log` when macOS
  shuts down properly, and wtmp gets a shutdown record; the power log adds shutdown, restart and wake-from-hibernation
  entries;
- otherwise, where the shutdown log reaches back over that session, a missing marker means the Mac stopped without
  shutting down (power loss, holding the power button, a freeze). That verdict is labelled *inferred*.

A Freezes panel lists app hangs from macOS's hang reports. When an unexpected shutdown or a panic happened since
FlightDeck last checked, it raises a finding once, about 30 s after launch, and never repeats it.

The unified log keeps only days (rotated by size) and the power log about a week, so FlightDeck saves each cause and
verdict it learns in `~/Library/Application Support/Flightdeck/boots.json` (90 days). The page says how far back each
source reaches. Log queries run only when the page opens, on Refresh, and once at launch for the current boot.

#### Boot and login time

The current boot split into phases, measured from launch times the kernel keeps: kernel start (`kern.boottime`) to
loginwindow, time at the login window (including typing the password), login (wtmp's console record) to the desktop
(Dock, Finder and the menu bar launched), and the login-items phase (until the last third-party process started within
3 minutes of login). These are to the second and say when each step *started*, not when it was ready. It lists the
login and background items that started during login, and the busiest processes in the first 5 minutes from the
black box when FlightDeck was itself running then (otherwise their CPU time since start, but only within an hour of
login). Each boot's timing is saved for 90 days for the trend chart; boot-to-login comes from wtmp for every boot.

#### What Changed

What changed on this Mac, and when: a read-only persistence and configuration log in the spirit of KnockKnock and
BlockBlock. About 90 s after launch and then every 15 minutes (and when the page opens or you press Check Now),
FlightDeck takes an inventory, compares it with the previous one and records each difference, kept 90 days in
`~/Library/Application Support/Flightdeck/Changes/`. A full inventory takes about a second. It covers, without root:

- **launch agents and daemons** (the three LaunchAgents/LaunchDaemons folders, as Startup Apps reads them): the
  program each runs, whether it starts at login or boot, who signed it;
- **system extensions** (`systemextensionsctl list`) and loaded **kernel extensions** (`kmutil showloaded`), third-party only;
- **configuration profiles**: your user's profiles (`profiles list`), DEP/MDM enrollment and the managed-settings
  domains in `/Library/Managed Preferences`. Profiles installed for the whole Mac can only be listed with root;
- **sharing services**: Remote Login, Screen Sharing, File Sharing, Remote Apple Events and Internet Sharing on or
  off (launchd's override database);
- **apps** outside `/System` (the Installed Apps inventory): installed, updated or removed, with version, bundle ID,
  signer and team ID (signatures are checked only for new and updated apps);
- **Homebrew** formulae and casks (folder listings of the Cellar and Caskroom; brew itself is never run), and the
  **macOS version**.

Each change shows when (the file's modification time, or for a macOS update the boot after it, when that falls
between two checks; otherwise when the check found it), what kind (added, removed, changed, updated), what it is, and
why it may matter. Notable changes are flagged and raised once as findings: unsigned or ad-hoc-signed code, a
program in a temporary, shared, hidden or home folder, a new third-party system or kernel extension, a new profile or
managed setting, an MDM enrollment, a sharing service turned on. The first inventory is the baseline and raises
nothing, as does a category the first time it can be read. Items link to Startup Apps, Installed Apps or Checkup.
Login items and SMAppService background items aren't tracked (listing them needs Automation permission or root).

### Activity

What is running and what it costs. Performance has tabs for CPU, Memory, Disk, Network, Energy, Thermals and GPU.

#### Performance

One page with a tab per subsystem. **CPU**: total, user and system load, load averages, and per-core tiles coloured by
performance/efficiency core (overall, logical-processor and cluster views, with live cluster clocks). **Memory**:
composition (app, wired, compressed, cached, free), pressure, swap, paging and compression rates, and memory by app.
**Disk**: read/write rates overall and per device, capacity per volume, top disk processes and drive health. **Network**:
bandwidth, interfaces, per-app traffic and connection quality. **Energy**, **Thermals** and **GPU** are described below.

#### Processes

The process list can be shown as a parent/child **Tree**, grouped by **Apps** (every helper rolled into its app, with
app-level Quit / Force Quit), or **Flat**. The filter understands queries: `cpu>50 mem>1g user:root app:chrome kind:intel gpu>0 wakeups>500 sleep hung` (terms combine; plain text matches name, path, user or PID). Right-click the column header to choose columns; layout persists. ⌘1–⌘9 jump between sections (Go menu). The **Kind** column shows Apple-silicon or Intel (Rosetta) binaries, and **Sleep** shows who is keeping the Mac or display awake (also a finding, with the reason the app gave). Apps the window server considers hung are marked **Not Responding** in red
and raise a warning finding.

#### Process inspector

Double-click a process (or ⌘I, or Inspect… in its menu) to open it in its own window:
CPU, memory, disk and network history (every process's last 300 samples are kept, not just the busiest), PID,
parent and children, user, start time, CPU time, energy, wake-ups, arguments, working directory (the environment is shown only where macOS allows it), code signature
(Apple, Developer ID, ad-hoc or invalid; team; hardened runtime), kernel statistics with rates (page faults, page-ins, Unix and Mach syscalls, context switches, Mach messages, resident/virtual and peak memory, instructions per cycle, logical writes), every open file descriptor, sockets with addresses
and TCP state, threads (CPU, state, priority, times), the environment, and call-stack sampling via
`/usr/bin/sample` to see why it's busy or hung. Actions: quit, force quit, suspend, resume, lower priority (nice).
Anything macOS doesn't let a normal user read for other users' processes is shown as unavailable.

#### Connection quality

*Performance › Network.* Wi-Fi signal, noise, SNR, link rate, channel, band, width, PHY and
security from CoreWLAN, plus router and DNS servers, all local. An opt-in probe (off by default) pings the router and
an internet host every 10 s, so FlightDeck can tell "your Wi-Fi is the problem" from "your internet provider is".

#### Energy and storage health

Performance › Energy has an **energy budget**: which apps used the most energy
(Wh and average W) over the last 1, 8 or 24 hours, how long the Mac ran on battery and how much charge that took,
and a battery charge history, all from the black box. Battery health uses the same capacity figure as macOS
(nominal ÷ design). Performance › Disk shows **drive health** from the SSD's NVMe SMART log (wear, spare,
lifetime reads and writes, power-on hours, unsafe shutdowns, media errors) and how many days until the startup
disk fills at the current rate. Unhealthy drives raise a warning.

#### Charging insights

*Performance › Energy.* What the charger negotiated, read from AppleSmartBattery via IOKit in
the same read as the battery readings: rated watts, the USB-PD offers and the one in use ("this charger offers
5/9/15/20 V; it's using 20 V × 4.7 A = 94 W", from `UsbHvcMenu`, or decoded from the USB-C port controller's PD
capabilities), the adapter type and the port controller carrying the contract. A **flow diagram** shows adapter → Mac
and adapter → battery (or battery → Mac) in watts each sample, from Voltage × Amperage and PowerTelemetryData. The
current charge session's **charge curve** (charge % and charge power, in memory only) comes with time to 80% and
100%, labelled as macOS's own estimate or the recent rate, an explanation of the constant-voltage slowdown above 80%,
and **hold detection**: plugged in but not charging (Optimized Battery Charging, a charge limit or heat), backed by
`pmset -g batt` wording and the charger's not-charging code when present. Weak chargers are flagged from measurements
only: macOS's slow-charging flag, the battery draining while plugged in, or a charger rated below the most this Mac
has drawn since launch. **Battery facts** add cycles vs design cycles, design vs full-charge capacity, temperature,
cell voltages, condition and the manufacture date where decodable, with a link to the health history in Trends.
Anything a Mac doesn't publish shows as "not reported by this Mac"; desktops get a "no battery" note.

#### Battery health forecast

![Battery health forecast (demo data)](docs/screenshots/battery-health.jpg)

*Performance › Energy, under Battery facts.* When will the battery reach 80% health, the usual service threshold, and
what is wearing it? It sits in Energy rather than Trends because it is about this battery's live facts and condition,
and its history reaches past Trends' 90 days.

- **History.** FlightDeck's daily log records health (nominal ÷ design capacity) and cycle count each day, and keeps
  these points for five years. The days just before FlightDeck started are seeded from macOS's own power log
  (`/private/var/db/powerlog`, world-readable, no root). It holds about ten days of the gauge's cycle count and
  capacity, plus lifetime figures: the hottest and coldest temperature the gauge has recorded, and its operating
  hours. AppleSmartBattery, IOPowerSources, `system_profiler` and `pmset -g log` were checked as well; they hold
  current values only. Seeded days show as hollow dots and never replace a day FlightDeck measured.
- **Forecast.** A Theil–Sen line runs through health against time, and another against cycles. Theil–Sen is the
  median of all pairwise slopes, so it is robust to the 1% steps, the day-to-day wobble and the jumps when the gauge
  recalibrates. Histories over 120 days are thinned to weekly medians. The chart shows the history, the trend and a
  95% band from Sen's slope interval. Below it are the 80% date and its range, the cycles at 80%, the cycles left
  before the design count, and the cycles per week. With fewer than 14 days or less than a 2% change in health, it
  doesn't forecast. Instead it says what is missing, for example "needs about 3 more weeks", or "no measurable
  decline yet". A battery replacement (the cycle count going down) starts the history over.
- **What's wearing it.** These are the known ageing factors, measured from the samples FlightDeck already takes,
  with O(1) work per sample:
  - time at 95% charge or more while plugged in;
  - heat: average battery temperature, and time above 35 °C and 40 °C;
  - deep discharges below 20% and 10%;
  - cycles per week;
  - how often Optimized Charging or a charge limit holds the charge (the existing hold detection).

  Each factor has a level and a plain-English tip. They are presented as contributors, not as a diagnosis.
- **Condition and service.** macOS's condition (from `system_profiler`), health against 80%, and cycles against the
  design count.

Desktops show "no battery". Demo mode shows an invented 400-day history.

#### Why is the fan loud?

*Performance › Thermals.* When fans spin above idle or thermal pressure rises, a card connects
fan speed (against its minimum and maximum), the hottest sensor, whether macOS is holding the CPU/GPU back for heat, and
which apps produce the heat, e.g. "Fan at 4,200 rpm (idle ~1,200) because the CPU is at 92 °C; Photos is responsible for
~60% of the power draw." On fanless Macs it explains throttling instead.

#### Thermals

*Performance › Thermals.* The Thermals tab is a full temperature monitor:

- **Sensor catalog.** Both sources are read on the same 4 s cadence: the HID temperature sensors ("PMU tdie1",
  "pACC MTR Temp Sensor0", "gas gauge battery", "NAND CH0 temp") and the SMC temperature keys that have a known meaning
  on this chip (Tp0*, Tg*, TB*T, TH0*, Ts*P, TW0P…; ~25 keys, ~6 ms). They become friendly names in groups: CPU
  performance and efficiency cores, GPU, SoC / die, memory, SSD, battery, Wi-Fi / Bluetooth, charger / power,
  palm rest / enclosure, ambient / airflow. SMC keys mean different things on M1, M2, M3, M4 and Intel, so they go
  through per-chip tables (`SensorKeyTables.swift`); anything not in a table keeps its raw name under **Other** rather
  than being guessed at. Where both sources report the same sensor (the battery's hottest reading, the SSD's NAND) and
  agree within 2 °C, one entry is kept, noting the other's name. Calibration references ("tcal") are listed but never
  counted as the hottest.
- **Highest by group:** a strip with each group's hottest reading now and its maximum this session.
- **Sensor list:** group headers (folding; Other starts folded), then every sensor with now, minimum, average and
  maximum since launch and a 5-minute sparkline. Columns sort; "Group" off gives one flat list. Click a sensor for its
  30-minute history graph. The statistics come from a small ring buffer (450 points per sensor, about 200 KB in
  total) updated once per sensor read; in replay they're rebuilt from the replayed frames.
- **Is the Mac slowing down for heat?** `pmset -g therm`'s CPU speed limit and scheduler limit (read every 30 s, only
  while this tab is on screen), the thermal pressure state and the GPU's heat cap give a yes/no with the reasons, and
  how long the Mac was throttled this session. A CPU speed limit below 100% for over a minute becomes a finding (it is
  only seen while the tab is open, since pmset isn't run otherwise).
- **Fan health:** each fan's RPM against its target, minimum and maximum, and percent of maximum. Findings flag a fan
  reading 0 RPM for 20 s while the Mac is hot (70 °C+) and the target is above 0, a fan more than 25% (and 300 rpm)
  short of its target for a minute, and a fan running 40% slower than the other although both were asked for similar
  speeds. Fanless Macs say so.
- **Temperature alerts** (Settings › Alerts › Temperature alerts): per group, "CPU above 95 °C for 2 minutes". All
  start off. Thresholds show in your unit and are stored in °C. A rule that holds becomes a caution finding, so it
  notifies with the usual mutes, delay and cooldown and goes into the Flight Log.
- **Menu bar** (Settings › General › Menu bar): add a group's hottest reading or one sensor ("CPU 72°") and,
  optionally, the fastest fan's RPM after any menu bar style.

How sure the names are, per chip: the common Apple-silicon keys (battery, Wi-Fi, SSD, airflow, palm rest) were checked
on an M1 Max against the HID battery and NAND sensors. The M1 Pro/Max/Ultra per-core keys come from the widely used
open-source key map and were checked on an M1 Max with a performance-core load. The M2, M3 and M4 per-core keys come
from the same map but haven't been checked on those chips. A base M1 gets no per-core SMC names (its HID sensors
already name the P and E clusters). Intel uses the classic keys every Intel Mac monitor reads. Chips the tables don't
know (newer than M4) get the common keys only.

#### GPU

*Performance › GPU.* Utilisation (device, renderer, tiler), active residency, live average clock and a
per-P-state histogram, GPU power, GPU memory in use against Metal's recommended working set, driver
**recoveries** (GPU hangs that macOS reset), thermal clock capping, per-app GPU share and total GPU time (also a
GPU % column in Processes and a graph in the inspector), live CPU cluster clocks, and Metal and display details.
The data comes from the accelerator's statistics and IOReport, readable without root. Energy channels macOS hides
from normal users (CPU, ANE, DRAM) are shown as unavailable, not 0. Findings cover GPU hangs, thermal capping,
GPU memory near its limit, and apps hogging the GPU.

#### Launches

This page lists process launches and exits seen between samples (name, PID, parent, user, lifetime), with
"launched N× in the last 10 minutes" grouping, and raises a finding when something respawns over and over. Processes that
live less than one sample interval are missed. The inspector also gains a **Memory** tab that breaks a process's memory
into heap, graphics, mapped files, code, stacks and so on (via `footprint`/`vmmap`; your own processes only).

#### Console

Errors and faults from the unified log over the last 5 minutes, hour or 24 hours, grouped by process and
subsystem with counts and sparklines, the noisiest processes, sample messages per group, a filter, and a live tail
(`log stream`, only while the window is visible). Keeps the newest 20,000 messages; 24 h queries are read newest-first in
hourly chunks with progress and Cancel, and stop at 1 million messages. macOS redacts message details it considers
private as `<private>`; the Console says how many are affected.

#### Camera & Mic

This page is a privacy watch. macOS lights a green or orange dot while the camera or microphone is in use, but
keeps no history and doesn't always say which app. This page shows what's in use right now and by which app, a
timeline (today, 7 or 30 days: one row per day, camera and microphone in separate lanes, midnight to 6 a.m. shaded)
and every session (device, app, start, end, duration), filterable by app and device. Sessions at unusual hours, while
the screen was locked or after 5 minutes without input, and an app's first use of a device are marked. **Only device
use is recorded, never audio or video, and the history stays on this Mac** (`camera-mic.json` in Application Support,
90 days; **Clear History** deletes it and the list of apps seen before).

- *Is it in use:* CoreAudio and CoreMediaIO property listeners (no polling) on every input and video device's
  "running somewhere" flag and on the device lists, so AirPods, a USB webcam or a Continuity Camera are picked up as
  they appear. A headset playing music also reports "running", so a microphone counts only when a process is reading
  it (CoreAudio's per-process input state, macOS 14.2+); a process tap (system-audio capture) isn't a microphone.
- *Which app:* in order of trust: (1) macOS's own indicator, which Control Center logs with the bundle ID in public
  text (`com.apple.controlcenter`, category `sensor-indicators`, "Active activity attributions changed to
  [\"mic:…\", \"cam:…\"]"); FlightDeck follows that log with `log stream` **only while a device is in use**, plus a
  one-off `log show` of the seconds before; (2) for the microphone, the CoreAudio process reading it, with its PID (an
  Apple daemon recording for the named app, like avconferenced for FaceTime, is folded into that app); (3) otherwise
  the session says **Unknown app**, or **likely X** when X was the frontmost app as the device came on. Guesses never
  count as an app's first use, and every session shows how its app was identified.
- *Cost:* with nothing in use it does no work (measured: 3 ms of CPU in 60 s idle). While a device is in use the
  filtered log stream used no measurable CPU in 90 s; each session start runs one ~0.4 s CPU backfill.
- *Alerts* (Settings › Alerts › Camera & Mic, both off by default): "an app uses the camera or microphone for the
  first time" and "any use while the screen is locked or the Mac is idle". They are findings, so they reach
  notifications (sent at once, not after the "sustained" delay), the menu bar and the Flight Log, and can be muted.
  The menu bar panel shows the camera or microphone and the app's name while either is in use (optional).
- *Limits:* sessions while FlightDeck wasn't running aren't seen; one already in use at launch is marked as
  "started at or before". CoreMediaIO has no per-process state, so a camera's app is known only from the indicator
  log; if a future macOS changes that message, cameras fall back to "unknown" or "likely" rather than a wrong name.

### Power

#### Power & Freq

The power state (source, battery, Low Power Mode, thermal pressure), the active power-management settings from
`pmset`, and each CPU/GPU cluster's frequency table (the DVFS states the chip can run at), for reading alongside the
live clocks in Performance.

#### Sleep & Wake

This page reads the power-management log (no root): every sleep session with why it slept, what woke it,
each dark wake (screen-off wakes for network upkeep, Power Nap, Bluetooth) in plain English, battery used overnight,
which processes scheduled wakes, and which apps kept the Mac awake and for how long.

### Network

#### Network map

The Network page is a map of the local network: this Mac, its interface (Wi-Fi with network name, access point BSSID and
channel), the subnet with every device seen on it, the gateway, and the path to the internet. Other interfaces (a VPN
tunnel, a second Ethernet) are separate branches. Click a device for its details: IPv4 and IPv6 addresses, MAC,
manufacturer (from a bundled table of ~13,000 MAC prefixes of common vendors, generated from the IEEE registry by
`scripts/gen-oui.py`), model, reverse-DNS and Bonjour names, advertised services, first and last seen, and a guessed type
(router, phone, computer, printer, TV, speaker, smart home, NAS, camera…) with the reason for the guess. A sortable list
of every device sits below. Sources: the ARP and IPv6 neighbour tables, the routing table, this Mac's interfaces,
CoreWLAN, reverse DNS and a Bonjour browse of ~25 common service types (with `_device-info` models). Randomized
(private) Wi-Fi MAC addresses are shown as "private address", never as a vendor. Nothing runs unless the view is open:
a full survey when it appears or on Refresh, then a re-read of the ARP table every 10 s. Two buttons send packets, and only
when pressed: **Active scan** pings each address of the subnet once (at most a /24, 50 per second) so every device
that's on answers ARP, and **Traceroute** traces the hops to 1.1.1.1. A Mac can't see link-layer topology (which switch
port or access point each device uses), so devices are drawn on their subnet, not wired to the router. macOS asks
for **Local Network** permission the first time; without it, macOS 27 returns an empty ARP table and blocks Bonjour, and
the view says so. The Wi-Fi name and BSSID need Location Services permission. In demo mode the view shows an invented
network.

#### Wi-Fi

The Wi-Fi page is an analyzer. *Your connection*: signal, noise, SNR and link rate, each of signal, signal-to-noise,
interference and channel width rated in plain English, the link rate against the maximum for its standard and width
(assuming two spatial streams, as most Macs have) and the likely reasons it's low (weak signal, noise, 2.4 GHz, a narrow
channel, an older standard, crowded airtime). *Link over time*: RSSI and noise, SNR and link rate while the page is
open, from the readings the sampler already takes every 5 s (nothing extra is read), with roams (the BSSID changed),
band and channel changes and drops marked. **Walk test** shows one big RSSI number and a quality bar for walking around
to find dead spots. *Nearby networks*: **Scan** runs one CoreWLAN scan and lists every network (SSID, BSSID, vendor
from the BSSID's prefix, signal, noise, band, channel, width, security, standard); the real width and position of wide
channels (up to 320 MHz) come from the beacons' HT/VHT/HE/EHT elements when macOS provides them. *Channel congestion*:
per band, the networks on each 20 MHz channel weighted by signal, with wide networks counted on every channel they cover
and your own network highlighted, plus a recommendation such as "Your network is on 5 GHz channel 36 (80 MHz) with
6 strong neighbours overlapping it; channel 149 looks clearer", always hedged as what this Mac hears from where it is.
With a UniFi console set up, its access points' own radio utilization is shown too (measured airtime, which is better
than a scan) and feeds the interference rating. A scan takes the radio off its channel for a moment, so FlightDeck scans
only when you press Scan or, if you tick the box, every 45 s while the page is open; never in the background. Scans and
link history are kept in memory only. SSIDs and BSSIDs need Location Services permission: without it macOS hides them
(and the beacon details), the page explains this and offers **Allow Location Access…**, which is the only place
FlightDeck asks. Channels, signal and congestion still work without it; your own access point is then picked out by its
channel and signal, and a roam can't be told apart from a channel change. In demo mode the page shows an invented
neighbourhood and link history.

#### Internet

*Speed test only on request or on the opt-in schedule.* The Internet page runs macOS's own `networkQuality` (Apple's
test servers) and shows download and upload in Mbps, responsiveness in RPM (round trips per minute under load, with
Low < 200 · Medium < 800 · High as FlightDeck's bands), idle latency and the loaded latency derived from RPM, then
explains the result in plain English: what the speeds are good for, bufferbloat (how much a busy link adds to latency),
and whether Wi-Fi (signal and link rate) or the router (latency probe) looks like the bottleneck, compared with the
link as it was when the test started. A test takes about 15–20 s and transfers real data (hundreds of MB on a fast
line). Settings › Network can schedule one every 1, 3 or 6 hours (off by default); scheduled tests only run while
FlightDeck runs and are skipped on battery below 20%, on hotspots or metered connections (`NWPath.isExpensive`) and in
Low Data Mode. Results are kept for 90 days in `~/Library/Application Support/Flightdeck/speedtests.json`, with 7- and
30-day charts. **Data usage by app**: today, 7 and 30 days per app (in and out, with a 30-day sparkline), the totals,
and a flag when an app's day is far above its own median day. Counted from nettop's per-process byte counters in the
daily log's 10 s per-app pass (no extra sampling; a restarted process starts a new counter), stored per day in the
daily log (`DayRecord.dataUsage`, optional so older logs still load). Only traffic while FlightDeck runs is counted;
days it didn't run are gaps. Demo mode shows invented tests and usage and never runs networkQuality.

#### Destinations

*Who each app talks to.* Per app, the remote hosts it exchanged traffic with: bytes today, over 7 and over 30 days (in
and out on hover), connection count, first and last seen, the ports and services (HTTPS 443, QUIC, DNS 53, SMB 445…),
and whether the host is on the internet or local (private LAN, carrier-grade NAT 100.64/10, IPv6 ULA, link-local,
multicast, loopback). A destination the app first contacted in the last 24 hours (and not in the 30 days before) is
badged **NEW**; today's volume at 5× or more of its typical day (and at least 50 MB, with 3 earlier days to compare)
is badged **UNUSUAL**; both are listed at the top. The search field answers "which apps talked to X" (domain, host
name or IP). The process inspector's Network tab shows the same list for the inspected app.

- *Collection:* no extra sampling. The per-connection deltas the nettop run already computes for Network by app are
  folded into per-app, per-IP rows on nettop's own queue: O(active connections) per run, about 0.2 ms for 100 active
  flows in a release build. At most 300 IPs per app per day are kept; the rest are counted in an "other destinations"
  row. Like all nettop data, connections that open and close between two samples, and bytes after the last sample
  before a connection closes, are missed. Unconnected UDP sockets have no remote address, so DNS traffic (sent by
  mDNSResponder on apps' behalf) isn't attributed to the app that asked.
- *Names:* reverse DNS (PTR records) for new remote IPs, looked up in the background through `dns_sd`. Lookups are
  rate-limited (4 at once, 10 a second), time out after 5 s and are cached (names 6 h, "no name" 1 h). Sampling never
  waits for them. Every name is labelled with its source: **reverse DNS** (published by whoever runs the IP, often a
  hosting or CDN provider, and not verified; names of known providers such as AWS, Akamai or Google are marked as
  the provider), **no name** (no PTR record), or **not looked up**. macOS doesn't let an unprivileged app see which
  name another app looked up (that would need a DNS-proxy or content-filter network extension), so FlightDeck never
  claims one. Internet hosts are grouped by registrable domain (`api.notion.com` → `notion.com`) using an embedded
  subset of the Public Suffix List; local hosts keep their full name, and unnamed ones their IP. Reverse DNS can be
  turned off in Settings › Alerts; destinations are then grouped by IP.
- *No country or ASN:* the free offline databases that could be bundled (DB-IP Lite under CC BY 4.0, IPtoASN
  in the public domain) are 7–25 MB uncompressed and go stale within weeks, and FlightDeck has no update channel for
  them. An outdated table would give confident wrong answers, so FlightDeck shows none, and it never asks an online
  geolocation service.
- *Alerts:* opt-in in Settings › Alerts: "an app contacted a destination it hasn't contacted in 30 days". An app is
  learned for a day first. Each app notifies at most once an hour (later new destinations join that finding). Web
  browsers and local-network devices are ignored by default.
- *Privacy and storage:* everything stays on this Mac, in `~/Library/Application Support/Flightdeck/Destinations/`:
  one JSON file per day plus `known.json` (the destinations each app contacted in the last 30 days), kept for 30 days.
  The open day is written every 5 minutes and at quit. The page can clear it all. The only network traffic this
  feature adds is the reverse-DNS queries to your configured DNS server. The `network_destinations` MCP tool reads the
  same data. Demo mode shows invented apps and destinations (Slack → slack.com, a "Mystery Helper" talking to
  unnamed documentation-range IPs) and collects nothing.

#### Connections

Your processes' network sockets as a sortable, filterable table (process, PID, protocol, local and remote address,
state), refreshed every few seconds, with the listening-ports panel on top (see Known limits for what it can see).

#### UPnP

The devices that answer UPnP discovery on the local network (an SSDP M-SEARCH, plus passive NOTIFY
announcements while the page is open; nothing runs in the background), drawn as a map with the router at the centre and
media renderers, media servers, printers and other devices around it. Click a device for its description: name,
manufacturer, model, device type, its web page, services and embedded devices (serial numbers are hidden unless you ask).
If the router is a UPnP Internet Gateway Device, **Router port mappings** lists every port it has forwarded at an app's
request (protocol, external port, the LAN device and port it goes to, the app's description, lease), with its external
IP and mappings to this Mac flagged, so it's clear which apps opened holes through the router. FlightDeck only reads
them; it never adds or removes a mapping. Descriptions are fetched only from the device that answered, with short
timeouts and size caps. macOS may ask for Local Network access the first time.

#### UniFi

*Settings › Network › UniFi, off until configured.* FlightDeck reads a UniFi network from a UniFi OS console (Dream Machine,
Dream Router, Cloud Gateway, Cloud Key) or a self-hosted UniFi Network application, and shows the real topology (gateway →
switches, with the port each device is on → access points → clients grouped under their AP or switch port, with link
speeds), device health (CPU, memory, temperatures, firmware, uptime, ports with PoE, AP radios with channel, utilization
and clients), clients (signal, channel, Wi-Fi standard, SSID, link speed, traffic and rates, sortable, plus the busiest
right now), and WAN health (WAN IP, ISP, throughput with a graph for the visible session, latency, uptime, the last
speed test). Setup: create an API key in UniFi Network › Settings › Control Plane › Integrations (or use a local
read-only account), enter the console's address, site (usually `default`) and key in Settings › Network › UniFi, press Test
connection, compare the certificate's SHA-256 fingerprint with the console's and trust it. The API key uses the official
Integration API, plus the classic `stat/*` endpoints with the same key where the console accepts it (they carry switch
ports, signal, traffic and WAN health); username/password uses the classic API. Read-only; credentials live only in the
Keychain; the trusted certificate is pinned (a changed one is refused). It polls every 15 s only while the UniFi view is
open. With nothing configured, opening the view checks whether the default gateway is Ubiquiti hardware (ARP) or answers
like UniFi OS (one unauthenticated HTTPS GET) and suggests it; no credentials are sent anywhere you haven't configured.
Anything the console doesn't report is shown as unknown. For other features, `UniFiSnapshot.attachment(ofMAC:)` and
`UniFiTopology` (FlightDeckCore) say which AP or switch port a MAC address is on.

#### Fleet

*Settings › Network › Fleet, off by default on every Mac.* Your other Macs running FlightDeck, on one page: a card per
Mac with its model icon, online/offline (and when it was last seen), CPU, memory-pressure and temperature sparklines for
the last 30 minutes, and its worst current finding. Click a card for a read-only detail panel: CPU, memory pressure and
use, hottest sensor, thermal state, startup-disk free space, battery, uptime, macOS and FlightDeck versions, current
findings and recent incidents. Values the other Mac couldn't measure show as "—" with its reason. To add a Mac, turn on
**Share this Mac with my other Macs** on it and click **Pair a Mac**; it shows a 6-digit code for 5 minutes. Its card
appears on your other Macs' Fleet page ("FlightDeck on Studio — pair to view"); click **Pair…** and type the code.
The page polls paired Macs every 10 s while open; otherwise every 5 minutes, so a paired Mac with a warning raises a
finding here ("Studio: Memory pressure is critical"). A sharing Mac does no work between requests apart from noting
four numbers every 30 s for the history.

Security: sharing Macs advertise `_flightdeck._tcp` over Bonjour and answer only private, link-local or loopback
addresses (never peer-to-peer or cellular interfaces). Without pairing a Mac learns only the other's name. Pairing is
Bluetooth-style Passkey Entry over X25519: six rounds in which the viewer commits to each digit of the code before the
host proves it knows it, so neither a listener nor a man in the middle can recover the code or the key (an active
attacker gets one 1-in-a-million guess per attempt); pairing is only accepted while the code is shown, any wrong or
abandoned attempt changes the code, and 5 failures pause pairing for 10 minutes. Every request is signed (HMAC-SHA256
over method, path, time and a one-time nonce; ±5 min clock window; replays refused) and every reply is encrypted and
authenticated with ChaCha20-Poly1305, bound to its request. Read-only: there is no endpoint that changes anything.
Shared data is limited to the vital signs above, finding kinds and wording (paths, URLs, e-mail, IP/MAC addresses,
host names and your user names are replaced; camera, microphone and destination alerts are never shared; no process
IDs, command lines or app identifiers) and the coarse history. Each Mac can remove a viewer (Settings) or forget a host
(the detail panel). Pairing secrets are kept in `~/Library/Application Support/Flightdeck/Fleet/fleet.json` (mode 0600
in a 0700 folder) rather than the Keychain: FlightDeck is ad-hoc signed, so each update would trigger Keychain access
prompts at random moments from the background poll. For testing without a second Mac, `FlightDeck --fleet-serve <port>`
serves this Mac on 127.0.0.1 and `FlightDeck --fleet-query 127.0.0.1:<port> <code>` pairs with it and prints the reply.

### Storage

#### Disk Space › Folder Scanner

The folder scanner measures the largest items in a folder you pick (or a whole volume), only when you
press Scan. While it runs, a progress strip shows the item being measured, how many of the folder's items are done,
files examined, size so far and elapsed time; rows still waiting show as "measuring…" or "waiting", and Cancel stops
it within milliseconds, even inside a huge folder. The scan keeps running if you switch to another page, and its
results are still there when you come back. Double-click a folder to drill in: the scan saves every folder's total,
subfolders and largest files as it goes (in a small SQLite file in `~/Library/Application Support/Flightdeck/`, written
as each folder finishes so memory stays flat), so drilling in and going back up are instant, and the last scan is
still browsable after a relaunch, labelled with when it ran. Rescan refreshes a folder; Forget Saved Scans deletes the
saved names and sizes. Only the latest scan of each folder (and five scans overall) is kept.

#### Disk Space › What's Using My Disk

*Next to the folder scanner.* The startup disk's APFS container as one stacked
bar, from `diskutil apfs list -plist` and `diskutil info -plist /` (no root): your data, purgeable space ("available
for important usage" minus available), the sealed macOS volume, Preboot, Recovery, swap (VM), Update, APFS overhead and
free, each explained. What Storage settings calls "System Data" is mostly the Data volume's caches, snapshots and app
files, and this view says so. Local Time Machine snapshots (`tmutil listlocalsnapshots /`) are listed with dates; their
sizes need root, so they show as unknown. Below that, **known space hogs**: app caches, logs, the Trash, old downloads,
iPhone/iPad backups, Xcode DerivedData, archives, device support and previews, simulator devices and runtimes (`simctl`
from the selected Xcode, never the `xcrun` shim, which can pop up an install dialog), Docker/OrbStack/Colima disk images,
the Homebrew cache (`brew --cache`), npm/Yarn/pnpm/pip/Cargo/Gradle caches, Mail downloads, Messages attachments, the
Photos library (size only), `Install macOS*.app` installers and Parallels/UTM/VMware VMs. Each says where it is, whether
it's safe to remove and what happens if you do. Nothing is measured until you press **Analyze** (with progress and
Cancel), because reading Downloads, Pictures, Mail, Messages, the Trash or other apps' containers makes macOS ask for
access; refused folders show as "not readable", never 0. Sizes are allocated bytes (`totalFileAllocatedSizeKey`).
Cleanups are only the safe ones: move a category's own items to the Trash (with a confirmation listing every item and
the total), Empty Trash via Finder, `simctl delete unavailable`, and `brew cleanup` after showing `brew cleanup -n`.
FlightDeck never deletes anything itself, never needs root and refuses any path outside the category's folders, outside
your home and /Applications, behind a symlink or SIP-protected. Afterwards it re-measures and reports before and after.
Personal data (backups, archives, Messages, Photos, VMs, container images) gets advice, not a button. Demo mode shows an
invented disk and never runs a cleanup. Code: `Sources/FlightDeckCore/StorageBreakdown*.swift`, `SpaceHog*.swift`,
`DirectorySizer.swift`, `CleanupPlanner.swift`; views in `Sources/FlightDeck/Views/StorageModel.swift` and friends.

#### Backups

*Is this Mac backed up?* Time Machine's state now (idle, backing up with phase, percent, bytes and files copied and
time left, automatic backups off, or not set up), each backup disk (network share or local disk, free and used space
with a free-space trend and "full in about N days", last successful backup, backups kept and the oldest, encryption,
last verification), a 90-day history strip of completed backups, failed runs and gaps, the runs themselves (start,
disk, outcome, duration, size copied), stretches with no successful backup ("9 days, Nov 1 → Nov 10"), why runs
failed in plain English with what to do (e.g. `BACKUP_FAILED_DISCONNECTED_NETWORK`: the share went away mid-backup)
plus the common reasons, and the local snapshots on the startup disk. Sources, none needing root or Full Disk Access:
`/Library/Preferences/com.apple.TimeMachine.plist` (world-readable; completed backup dates per destination, as
`tmutil listbackups` would print them, plus space, last result code, encryption and verification dates),
`tmutil destinationinfo -X`, `tmutil status -X`, `tmutil listlocalsnapshots /`, and backupd's run messages in the
unified log (`log show --info`, categories BackupJob, BackupEngine, BackupDispatching, ErrorEvaluator; scheduler
"BACKUP_DELAYED" messages are ignored). Limits: backupd logs runs at the Info level, which macOS keeps only a day or two,
so durations, sizes and failures are known only from when FlightDeck started reading them; FlightDeck saves them, the
backup dates (which Time Machine thins to weekly after a month) and free-space points for 90 days in
`~/Library/Application Support/Flightdeck/Backups/backups.json`. Gaps ending more than a month ago are only shown when
over 8 days, since thinning would otherwise look like missed backups. Snapshot sizes need root and show as unknown.
`tmutil listbackups`/`latestbackup` are not used: they need Full Disk Access and can mount a network disk. Cost: the
settings file and tmutil are read every 15 minutes (milliseconds, nothing mounted) and the log every 6 hours over the
hours since the last read, plus on page open; progress is re-read every minute only while a backup runs and the page
is open. With automatic backups on and no successful backup for three missed intervals (at least 3 days), the finding
"No successful Time Machine backup for N days" appears in the banner, alerts and Flight Log (a warning after 30 days)
until the next backup. Demo mode shows an invented NAS and travel SSD. Code: `Sources/FlightDeckCore/Backup*.swift`,
`BackupsCollector.swift`, `MCPBackupsOutput.swift`; views in `Sources/FlightDeck/Views/Backups*.swift`.

### System

#### System Info

This Mac's hardware and software at a glance: model, chip and cores, memory, macOS version and build, serial number and
hardware UUID, security settings such as SIP, storage and uptime.

#### Installed Apps

Every app in the Applications folders with its version, vendor, architecture (Apple silicon, Intel or Universal),
source (System, App Store or other), size (Compute Sizes measures them in the background), modification date and
bundle ID. Every column sorts; filter by name or bundle ID, hide system apps, and open or reveal any app.

#### Startup Apps

This page shows who signed every launch agent, daemon and login item, flags unsigned ones, and marks items
whose program no longer exists (leftovers from removed apps), with a summary at the top.

After each wake, a restless or draining night (30+ dark wakes, or 10%+ battery lost while asleep) becomes a finding that names the main cause.

#### Peripherals

**Link speeds** compares, for every USB and Thunderbolt/USB4 device, the speed it negotiated with what the device
supports and what its port (or the hub in front of it) supports, and says why in plain English: "Ridgeline Portable
SSD is running at USB 2 (480 Mb/s) but supports 5 Gb/s: the cable or adapter is limiting it — try a USB-C cable rated
10 Gb/s, or plug it straight into the Mac", a USB 2-only hub in the chain, or "This Thunderbolt dock is linked at
20 Gb/s (Gen 2 ×2), not 40 Gb/s". Drives show the most they can transfer over the link (about 40 MB/s at USB 2).
Everything comes from documented IORegistry keys (`UsbLinkSpeed`/`USBSpeed`, `bcdUSB`, the port's USB 3 companion,
the USB-C port's transports and cable flags, and the Thunderbolt lane adapters' current/supported speed and width).
A USB 3 device that fell back to USB 2 describes itself like a USB 2 device, so that case is diagnosed only when its
descriptor says USB 3 or it is an SSD, and the latter is marked "probably". IOKit plug/unplug notifications (no polling)
re-read the links, and a drive linked well below its capability raises a finding once per plug-in.

**Accessory batteries** shows each accessory's level (AirPods per bud and case) with a 30-day sparkline and an
estimate such as "about 9 days left at this rate", a Theil–Sen fit over the readings since the last charge (or the
reason there is none yet). Apple's Magic Mouse/Keyboard/Trackpad publish their level in the IORegistry, read every
20 minutes; AirPods and other headsets only report through `system_profiler`, so their levels are recorded only when
the page loads. History is kept for 60 days in `~/Library/Application Support/Flightdeck/Accessories/` (one JSON
file per month, only changes and two-hourly repeats). A main battery dropping below 15% raises a finding once per
discharge.

Below those: the USB tree (speed, power drawn), Thunderbolt/USB4, displays (resolution, refresh, HDR), Bluetooth
devices with battery levels, audio devices and the power adapter. Demo mode shows an invented desk. **Connections** adds **listening ports**: which
process listens on which port, flagging services open on all interfaces. It uses `netstat` (every process) when macOS
gives the app the socket table, and otherwise falls back to `lsof` (your own processes only) and says so; on macOS 27,
netstat launched from an app returns no Internet sockets even though it works in Terminal.

#### Displays

Every connected display, and why it might not be running at its best. Per display:

- **Identity:** name, built-in or external, vendor and model, manufacture week and year (EDID), size in inches,
  a panel hint where something says so (mini-LED for a Liquid Retina XDR panel, OLED by name; never guessed), the GPU
  driving it and which display is main.
- **Mode and refresh:** "looks like" size in points, pixels and HiDPI scale, the native size, refresh rate, and
  ProMotion / Adaptive-Sync with its range (NSScreen's refresh intervals). The full CoreGraphics mode list, grouped by
  size, is one click away with native and current marked.
- **HDR and colour:** HDR state, EDR headroom now against the potential, the reference headroom when a preset sets
  one, the colour format on the wire (bit depth, RGB / YCbCr chroma) and the ColorSync profile; built-in brightness
  (DisplayServices, read-only, resolved with `dlsym` and shown as unavailable if it's missing) with the backlight's
  nits.
- **Connection:** transport (this Mac's HDMI port, USB-C DisplayPort Alt Mode, Thunderbolt / USB4 tunnel, virtual
  for AirPlay / Sidecar / DisplayLink), port, DisplayPort link rate × lanes with usable Gbit/s, DSC on or off, and the
  HDMI version the display's input reports in its EDID.
- **Diagnoses** in plain English, with the bandwidth sums behind them (CVT-RB2 / CTA-861 pixel clocks, DisplayPort
  8b/10b and 128b/132b payloads, HDMI 1.4 / 2.0 TMDS and 2.1 FRL limits): stuck at 30 Hz because an HDMI 1.4 link or
  input can't carry 4K at 60 Hz (594 MHz needed, 340 MHz available), a DisplayPort link trained on 2 of 4 lanes by a
  hub, a 60 Hz mode that exists but isn't chosen, 4:2:2 / 4:2:0 chroma or 6-bit colour for lack of bandwidth, DSC in
  use, HiDPI not offered at the current size, a scaled resolution, ProMotion turned off.
- **This session:** connects, disconnects, mode and main-display changes as a timeline and a list, recorded from
  CoreGraphics' reconfiguration callback from launch (no polling; kept in memory only).

On Apple silicon the facts come from the display coprocessor's IORegistry nodes (`AppleCLCD2`
timings and colour modes, `IOPortTransportStateDisplayPort` link state) and the EDID via `IOAVServiceCopyEDID`; Intel
Macs get the CoreGraphics and NSScreen parts. The page reads when it appears and when macOS reports a display
change, never on a timer. Limits: HDR reference presets are only readable through private APIs; YCbCr encoding codes
are inferred (RGB is confirmed); with several external displays, links are listed without saying which display each
drives.

#### Services

The launchd jobs in your login session: label, PID, running or stopped, the last exit status (non-zero ones stand out)
and domain, with a running-only filter and a Copy Label action.

#### Users

Who is logged in (console and remote sessions, with login times) and resource use by user. Other users' processes
need root to measure, which the page says.

### Tools

#### Rules

Rules automate responses: "when app *Chrome* has CPU % above 300 for 10 minutes, notify me / lower its priority /
suspend / quit / force quit / run a command". Commands get `FD_RULE`, `FD_SUBJECT`, `FD_PIDS`, `FD_METRIC` and `FD_VALUE`
in their environment (names are never spliced into the shell). Rules fire once per occurrence with a cooldown, signals
are identity-checked, and every action posts a notification and lands in the Flight Log and a saved action log.
Safety rails: quit/suspend/renice never touch macOS components (anything under /System, /usr, /bin, /sbin), Finder, Dock,
terminals, the app you're using, or FlightDeck itself; app rules quit through the app (so it can ask to save);
destructive rules always wait at least a minute, and a match-everything destructive rule must be explicitly confirmed;
suspended apps resume automatically (and when FlightDeck quits); commands time out after 60 s with their output logged.
"Test Against the Last 24 Hours" dry-runs a rule on the black box before you save it.

#### Developer

For people who code on this Mac. **Dev servers** lists your own processes listening on TCP ports that are
recognised developer tools (Vite, Next.js, webpack dev server and other Node/Bun/Deno servers; uvicorn, gunicorn, Flask,
Django runserver, Jupyter; Rails and Puma; Gradle, Spring Boot and other Java; `go run` and Cargo builds; PHP;
Postgres, MySQL, Redis, MongoDB; Ollama and LM Studio; Docker, OrbStack and Lima port forwarders), identified from the
executable and command line. Each row shows the port, a clickable `http://localhost:PORT`, the project folder (the
process's working directory), uptime, CPU and memory, with Open in browser, Reveal project, Inspect and Stop (SIGTERM
after a confirmation, then an offer of SIGKILL if it is still the same process 3 s later; identity-checked, own
processes only). **Containers** uses whichever docker CLI is installed (Docker Desktop, OrbStack, Colima, Rancher
Desktop): `docker ps -a` and `docker stats --no-stream`, the engine's own CPU and memory on the Mac, and start / stop /
restart with confirmation. **Homebrew services** (`brew services list --json`) with start / stop / restart (services
running as root need `sudo` in Terminal and are left alone). **Builds running** sums xcodebuild, swift-frontend, clang,
the linker, cargo/rustc, Gradle, tsc, esbuild and friends with CPU and elapsed time, and the load strip says whether
your build is what's heating the Mac. **Simulators** lists booted devices (`xcrun simctl list devices booted -j`) with
the CPU and memory of each device's process tree. **Toolchains** shows Xcode (`xcode-select -p`, `xcodebuild
-version`, other Xcode apps by Info.plist) and the Swift, Node, Python, Go, Rust, Java and Ruby versions found on disk:
xcrun stubs only run when a developer directory is selected, `/usr/bin/java` only when `java_home` finds a JDK, and
version-manager shims (pyenv, rbenv, nodenv, asdf) are never run (their global version file is read instead).
**Port finder** answers "what's using port N?" for every process netstat can see, plus containers publishing the
port, with a jump to the inspector. Nothing runs while the view is closed: dev servers and containers refresh every
5 s while it is open, Homebrew and simulators every 30 s, toolchains on open and Refresh. Unknown values show "—" with
the reason. In demo mode it shows an invented set of servers, containers and services and runs no actions.

#### Benchmarks

Short synthetic tests (CPU single-core and multi-core, memory bandwidth, disk sequential write and read), one at a
time so they don't skew each other, with the best score on this Mac remembered.

## Recording and replay

### Flight Recorder

Record (⇧⌘R) captures every telemetry frame and saves it as a `.flightlog` file
(zlib-compressed JSON). Open it (⌘O, or double-click in Finder) to scrub or replay it through the same views. Older `.mltrace` recordings from before the rename still open.

### Black box

An always-on rolling recorder (on by default; Settings › Recording turns it off or clears it). It keeps every sample
for the last hour and one sample every 10 s for 24 hours, capped at 50 MB, in
`~/Library/Application Support/Flightdeck/BlackBox` as ordinary `.flightlog` segments. Recorder › Save from Black Box
saves the last 5 minutes to 24 hours after the fact; Recorder › Replay Black Box (⇧⌘B: last 10 minutes) replays it.

### Export

Recorder › Export writes a one-page **PDF flight report** (findings, average/95th/peak statistics,
top apps, graphs) or **CSV** (system metrics, or per-process) for the replayed recording, or the last hour of the
black box when live. Unmeasured values are empty CSV cells, not zeros.

### Compare recordings

*Recorder › Compare Recordings….* Two `.flightlog` files side by side, for example before
and after an update. Shows average and 95th-percentile statistics with the change in each, overlaid graphs aligned by
elapsed time, and which apps' CPU use changed.

## Everywhere in the app

### Settings and appearance

Settings has five tabs: **General** (theme, Dock icon, sample interval, temperature unit °C/°F, Stress Map animation,
menu bar), **Alerts** (notifications, thresholds, mutes, temperature and camera/mic alerts), **Recording** (the black
box), **Network** (latency probe, speed-test schedule, UniFi) and **Integrations** (Prometheus and MCP). Themes: Light,
Dark, **System** (follows macOS's appearance and switches with it), and four single-hue phosphor looks (green, amber,
blue, mono). FlightDeck › About shows the version.

### Master caution

A menu bar instrument strip (caution light, CPU and memory bars; or CPU % or the light alone)
opens a panel with the caution status, gauges, findings, top apps and quick actions. With it on, closing the window
keeps FlightDeck running, so the black box and alerts continue (Settings › General › Open at login). Sustained cautions and
warnings also post a notification (after 2 minutes by default, once per occurrence, at most every 30 minutes per
problem; click to jump to the right view), and light an amber or red caution lamp on the Dock icon.

### Live Dock icon

Right-click the Dock icon (or use Monitor › Dock Icon, or Settings) to pick a mode:
CPU History (scrolling graph), CPU Cores (one VFD column per core, coloured by P/E), System Gauges (CPU, memory
and temperature), or the static App Icon. It follows the current theme and shows a red tally light while the
Flight Recorder is recording. The static `AppIcon.icns` is rendered by the same code at build time
(`FlightDeck --render-iconset <dir>`); `--render-dock-previews <dir>` writes every mode × theme as a PNG.

### Command palette

*⌘K, View › Command Palette….* Type to jump to any view or Performance tab, find a running app or
process (then inspect, sample its stacks, reveal it in Finder, quit or force quit, with the usual confirmations), or run a
command (record, save or replay the black box, open a flight log, capture diagnostics, Settings).

### Capture Diagnostics…

*Help menu, or the palette.* This writes one folder or zip for a bug report: the black box's last
10 minutes, a text summary (system, findings, top processes; no serial number or hardware UUID), macOS crash and hang
reports from the last 24 hours, 2-second stack samples of the busiest and any hung app of yours, and recent unified-log
errors. It may contain personal paths and names, so review it before sharing.

## Integrations

### AI assistants (MCP)

*Settings › Integrations › AI assistants, off by default.* FlightDeck serves the
[Model Context Protocol](https://modelcontextprotocol.io), so Claude Code, Codex and other MCP clients can answer
"why is my Mac slow?" from FlightDeck's real data. Tools, all read-only except `mark`, which only adds to FlightDeck's own marks file:

| Tool | What it returns |
|---|---|
| `triage` | one call for "what's wrong right now?": every current problem (findings, ongoing Flight Log incidents, crashes/hangs/panics of the last 24 h, unexpected restarts of the last 7 days, memory pressure, heat, a full disk, low battery) ranked by severity, each with evidence numbers and the next tool to call with its arguments; plus the headline readings |
| `get_status` | findings in plain English, CPU/memory/swap/disk/network/power/thermal/GPU, top apps by CPU, memory and energy, Stress Map top causes |
| `list_processes` | processes or apps as a table; `sort`, `limit`, `filter` (the Processes filter syntax, e.g. `cpu>50 user:root`), `by_app` |
| `get_process` | one PID: identity, path, user, parent chain, CPU, memory, energy, disk, network, listening ports, open files, code signature; optional arguments/files/sockets/threads |
| `sample_stacks` | 1–5 s of `/usr/bin/sample` on one of *your* processes: main-thread summary and heaviest path |
| `recent_incidents` | the Flight Log over the last N hours |
| `diagnostic_reports` | macOS crash, hang, memory-kill and resource-limit reports, with counts by kind and process |
| `history` | black-box average/p95/peak, top apps and problems over the last N minutes (up to 24 h) |
| `checkup` | the Checkup list, items needing attention first |
| `trends` | daily rollups (or one app's days) and before/after comparisons of updates |
| `temperatures` | every sensor by group with now/min/avg/max since launch, the hottest per group, fans with target/min/max and problems, and throttling (pmset limits, thermal state, GPU heat cap, time throttled) |
| `wifi` | the Wi-Fi link with health ratings and low-rate reasons, and a summary of the last scan run in the app (networks per band, busiest channels, strongest networks, a channel recommendation). Never scans; SSIDs and BSSIDs only with Location permission |
| `camera_mic` | whether a camera or microphone is in use now and by which app, recent sessions (device, app, times, duration) with how each app was identified (confirmed / likely / unknown), first use, unusual-hour and locked/idle flags, and per-app totals |
| `battery` | battery facts (health, cycles against the design count, capacities, temperature, condition, the gauge's lifetime extremes), service status, the 80% forecast with its 95% range or exactly what data is missing, and the wear factors with tips |
| `network_destinations` | per app (optionally one app, or only destinations matching a host or IP), the remote hosts it talked to over 1–30 days: bytes in and out, connections, first and last seen, services, local or internet, name source, and new / unusual-volume flags |
| `restarts` | every boot with how the session before it ended (clean / unexpected / kernel panic / unknown), the explanation, saved shutdown cause code with its certainty, evidence and an inferred flag; counts by cause; boot and login timing; recent app hangs; what the records can't tell. Never queries the unified log |
| `panics` | kernel panic reports: time, culprit, what to do, panic string, panicked task, kexts in the backtrace |
| `system_changes` | what FlightDeck's What Changed inventory found over the last N days or `since` a time: launch agents and daemons, system and kernel extensions, profiles and MDM, sharing services, apps, Homebrew, macOS updates; each with when, the item, signer and team, program and path, why it may matter and a notable flag; `kind` filter and `notable_only`. Reads the saved log, never takes an inventory |
| `weekly_report` | one calendar week (`weeks_ago`: 0 = this week so far, 1 = last week): the headline, hours of high CPU / memory pressure / heat with the top incidents and apps, busiest apps, restarts, panics, freezes and crash reports, battery cycles, health and forecast change, startup-disk use, internet data and new destinations, plus the report as Markdown. Finished weeks come from the saved reports |
| `backups` | Time Machine: state now and progress, each destination (kind, space and trend, last successful backup, backups kept, encryption), recent runs with duration, size and plain-English failure reasons, gaps, local snapshot count, limits. Read-only; never runs `log show` or mounts a disk |
| `displays` | every display: identity, connection, current mode and refresh range, signal (timing, pixel clock, bit depth, chroma, DSC), DisplayPort link rate × lanes, HDR / EDR headroom, built-in brightness, diagnoses with bandwidth figures, and this session's connects and mode changes (app only). Never includes serial numbers |
| `peripherals` | USB and Thunderbolt/USB4 devices: negotiated vs supported link speed, hubs in the chain, a drive's realistic MB/s and why it's slower than it could be; accessory batteries with time left |
| `fleet` | the Macs paired on the Fleet page, each asked for its status now: online or last seen, model, macOS, vital signs (CPU, memory, hottest temperature, startup disk, battery, uptime, thermal state), its worst problem, findings and recent incidents. Only what each Mac shares (redacted); up to about 6 s when one doesn't answer |
| `mark` | records a named timestamp (`label`) and returns its id and time, and whether the black box is recording. Writes only `~/Library/Application Support/Flightdeck/marks.json` (kept 48 h); marks show as flags on the Flight Log timeline |
| `marks` | recent marks, newest first |
| `measure` | what the Mac did between two marks, times, or a mark and now (within 24 h): CPU avg/p95/peak and CPU-seconds, memory and pressure, swap growth, disk and network totals, energy (Wh), hottest temperature and throttling, top processes and apps by CPU-seconds, peak memory, energy and disk. `process` or `app` gives that process tree's cost, children included; `compare_to` adds a baseline window, deltas and a verdict |
| `query_metrics` | raw black-box series on a regular grid, columnar (`t` offsets plus one array per metric): `cpu`, `cpu_user`, `cpu_system`, `memory_used`, `memory_pressure`, `swap`, `disk_read`, `disk_write`, `net_in`, `net_out`, `watts`, `hottest_c`, `gpu`, `battery_pct`, `process:<pid or name>.cpu\|rss\|energy`. Automatic step (≤ 300 points), average or max per slot as stated, gaps as `null` |
| `process_logs` | unified-log messages for an `app`, `pid` or `subsystem`, grouped (messages differing only in numbers or ids collapse) with counts, newest first; `level` error (default), fault, default or info; up to 24 h of errors or 60 min of default/info; 20 s and 20,000-message bounds; notes `<private>` redaction |
| `wait_for_event` | blocks until something happens (an incident opens or closes, a new finding, a crash/hang/panic report, a thermal state change, low battery), filtered by `kinds`, `app` and `min_severity`, or with `until_cpu_below` until CPU has stayed below that % for `settle_seconds`; `timeout_seconds` up to 600; `after_seq` so nothing between two calls is missed |

### Guided prompts

*MCP prompts; Claude Code shows them as `/mcp__flightdeck__<name>`.* These run a whole investigation with
those tools and report in plain English: `triage`, `diagnose_slow_mac`, `investigate_app` (needs `app`), `battery_drain`,
`thermal_check`, `crash_triage`, `health_checkup`, `since_update`, `what_changed` (optional `days`), `backup_check`,
`display_check`, `weekly_review`, `fleet_check` and `measure_change` (needs `command`; optional `process`). They only call FlightDeck's tools and tell the assistant to suggest, not perform, any fix; `measure_change`
also runs the workload you name, twice (baseline and with your change), between marks.

### Measuring your own work

Coding agents can ask "did my change make the tests slower or hungrier?" and get numbers instead of impressions. The
agent calls `mark` before and after a run, then `measure` between the marks; with `process` it gets that process tree's
cost (a build tool and every compiler or test worker it spawned), and with `compare_to` a baseline run's figures, the
change in % and a verdict. The FlightDeck app must be running, since its black box is what records; `FlightDeck --mcp`
standalone still stores marks, and says plainly when there is nothing recorded to measure. Marks appear on the Flight
Log timeline as labelled flags, so you can see what your agent measured.

```text
mark {"label": "baseline-start"}   … swift test …   mark {"label": "baseline-end"}
mark {"label": "change-start"}     … swift test …   mark {"label": "change-end"}
measure {"from": "change-start", "to": "change-end", "process": "swift-build",
         "compare_to": {"from": "baseline-start", "to": "baseline-end"}}
```

Part of the answer (illustrative numbers):

```json
"summary": "Over 2 min, the swift-build process tree (214 recorded processes, 211 started in the window) used 812.4 CPU-seconds (6.8 cores on average), peaked at 5.1 GB of memory, drew 1.10 Wh and did 1.4 GB of disk I/O.",
"comparison": {
  "verdict": "Compared with the baseline, the swift-build process tree was slower and hungrier: it took 18% longer, CPU time 23% higher, peak memory 9% higher.",
  "rows": [["duration_s", 141.2, 119.6, 18.1, "18% higher"], ["cpu_seconds", 812.4, 660.3, 23.0, "23% higher"], …]
}
```

Process costs come from each process's cumulative CPU time, energy and disk counters, so a child seen once in the black
box is counted in full up to that sighting. Processes that live less than one sample interval (1 s in the last hour,
10 s beyond) or never rank among the 25 busiest per frame aren't seen, so tree totals are lower bounds; the answer says
so. Differences under 5 % (or tiny in absolute terms) are called "about the same". With a filter, a `whole_mac` block
compares the rest of the Mac too, so a busy browser or thermal throttling during one run is visible.

### Notifications for agents

Instead of polling, a client can be told when something happens on the Mac: a Flight Log incident opens or closes
(a sustained CPU hog, memory pressure, heat, a hang, a disk filling…), a new finding appears or gets worse, a crash,
hang, memory-kill or panic report is written, the thermal state changes, or the battery runs low. FlightDeck serves
five resources (`resources/list`, `resources/read`; each reads like the matching tool): `flightdeck://events` (the
latest events; subscribing to it means every event), `flightdeck://incidents`, `flightdeck://findings`,
`flightdeck://reports` and `flightdeck://status` (thermal and battery). Every notification carries the event itself in
`_meta["app.flightdeck/event"]` (kind, severity, title, detail, app, pid, since, key, `next_tool`), so the client can
act without reading the resource again:

```json
{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"flightdeck://incidents","_meta":{"app.flightdeck/event":
 {"seq":1,"event":"incident_opened","severity":"warning","title":"Xcode is using 412% CPU","app":"Xcode","since":"2026-11-19T10:00:00-08:00",
  "key":"cpu:com.apple.dt.Xcode","uri":"flightdeck://incidents","next_tool":"recent_incidents"}}}}
```

- **2025-06-18 / 2025-11-25 clients**: `resources/subscribe` and `resources/unsubscribe` (capability
  `resources.subscribe`). Over stdio the notifications arrive on stdout. Over HTTP, `initialize` returns an
  `Mcp-Session-Id`; subscribe with that header and open `GET /mcp` (`Accept: text/event-stream`) with it to receive
  them as Server-Sent Events (notifications are held, up to 50, until the stream opens). `DELETE /mcp` ends the session.
- **2026-07-28 clients**: `subscriptions/listen` with `notifications.resourceSubscriptions`; the server acknowledges
  with `notifications/subscriptions/acknowledged` and tags each update with `io.modelcontextprotocol/subscriptionId`.
  Over HTTP the POST's response is the SSE stream; over stdio, `notifications/cancelled` ends it.
- **Claude Code channels** (research preview): `FlightDeck --mcp --channel` declares `experimental["claude/channel"]`
  and pushes each event as a `notifications/claude/channel` message, so the session sees
  `<channel source="flightdeck" event="incident_opened" severity="warning" app="Xcode" …>`. Start Claude Code with
  `claude --dangerously-load-development-channels server:flightdeck` while channels are in preview.
- **Clients without notifications**: `wait_for_event` blocks until a matching event (or until CPU settles), up to 10
  minutes. Set the client's tool timeout above the `timeout_seconds` you pass.

Events are found by comparing the state FlightDeck already keeps (every 5 s in the app, 15 s standalone, where each
check takes a sample), and only while a client is subscribed or waiting: with nobody listening there is no timer and
no extra work. A new subscriber hears about what happens from then on; `triage` and the resources say what is already
true. The stdio proxy relays the app's event stream (a `subscriptions/listen` to the HTTP endpoint) and falls back to
its own standalone watcher when the app isn't reachable. At most 4 notification streams are open on the HTTP endpoint
at once.

No tool can quit, kill, renice or change anything. Unmeasured values are marked "unavailable", never 0, and every
answer is capped at 48 KB. Two ways to connect:

- **HTTP, served by the running app.** Turn on Settings › Integrations › AI assistants. It listens on `http://127.0.0.1:9465/mcp`
  (port configurable; this Mac only), requires the bearer token shown there (generated on first enable; New Token
  replaces it), and refuses requests whose `Origin` or `Host` isn't this Mac (DNS rebinding). Settings shows these
  commands with your port and token filled in, each with a Copy button:

  ```sh
  claude mcp add --transport http flightdeck http://127.0.0.1:9465/mcp --header "Authorization: Bearer <token>"
  ```

  Codex, in `~/.codex/config.toml`:

  ```toml
  [mcp_servers.flightdeck]
  url = "http://127.0.0.1:9465/mcp"
  http_headers = { "Authorization" = "Bearer <token>" }
  ```

- **stdio, as a command** (`FlightDeck --mcp`), for any client and with no token to copy:

  ```sh
  claude mcp add flightdeck -- /Applications/FlightDeck.app/Contents/MacOS/FlightDeck --mcp
  codex mcp add flightdeck -- /Applications/FlightDeck.app/Contents/MacOS/FlightDeck --mcp
  ```

  When the app's server is on and answering, each message is forwarded to it (live findings, Flight Log, black box).
  Otherwise `--mcp` answers standalone: it samples on demand, reads the incident log, black box, daily log and macOS
  reports from disk (read-only), and every answer says `"source": "standalone"` with what that lacks (findings that
  need minutes of samples). Only protocol messages go to stdout.

The server speaks both MCP eras: `initialize`-based revisions 2024-11-05 to 2025-11-25, and the stateless 2026-07-28
revision (per-request `_meta`, `server/discover`). It does no work between requests unless a client is subscribed or waiting for an event. In demo mode the HTTP server
doesn't start (an assistant must not be handed invented data as facts about this Mac); `--mcp` then answers standalone
from real samples.

### Prometheus endpoint

*Settings › Integrations › Metrics export, off by default.* FlightDeck serves the latest sample as Prometheus text on
`http://127.0.0.1:9464/metrics` (port configurable, localhost only): CPU total/user/system and per core, memory,
pressure, swap, disk and network rates, system watts, hottest temperature, thermal state, fan RPM, GPU %, battery %, and
the top 20 processes by CPU (`name`, `pid` labels). Unmeasured values are omitted, never exported as 0. It does no work
between scrapes.

### Command line

The app binary doubles as a CLI
(`alias flightdeck=/Applications/FlightDeck.app/Contents/MacOS/FlightDeck`):

```sh
flightdeck --snapshot [--top N]     # summary, top apps and findings after a 1 s warm-up
flightdeck --snapshot --json        # full snapshot + findings as JSON (for scripts and Shortcuts)
flightdeck --json-stream [2] [--top 20]   # one JSON snapshot per line every 2 s (default 1 s) until interrupted
flightdeck --findings               # what's wrong right now
flightdeck --stats rec.flightlog    # statistics and findings of a recording
flightdeck --csv rec.flightlog out.csv [--processes]
flightdeck --report rec.flightlog out.pdf
flightdeck --mcp                    # MCP server on stdin/stdout for AI assistants (see AI assistants above)
flightdeck --render-views <dir>     # write 2x PNGs of the main views with live data (visual review, no window)
flightdeck --bench-ui [N]           # render every main view off-screen N times with live data; ms per frame
```

Six themes: Light, Dark, Green, Amber, Blue, Mono.

## Measurement principles

- **No invented zeros.** Every value is `Measured<T>`, either `.value` or `.unavailable(reason)`. Unmeasured
  values show "—". Examples: other users' processes without root, the first sample before deltas exist,
  Macs without sensors.
- **Gaps, not interpolation.** Pausing or missed samples are stored as `nil` and drawn as line breaks, both live and in replay.
- **Light in the background.** With no FlightDeck window on screen, view updates stop (graphs catch up instantly when you return) and sampling drops to every 2 s (Settings); the black box, findings and alerts keep running. Background cost is about 2.5% of one core.
- **Self-monitoring.** FlightDeck appears in its own process list by default (Settings → toggle).
- **Identity-safe actions.** Signals are sent only if the PID still has the same start time (`ProcessIdentity`).
- **Private by design.** FlightDeck sends no data anywhere. By default it makes no network requests at all; the only exception is the opt-in latency probe (Settings › Network › Network quality), which pings your router and one host you choose. The opt-in Prometheus and MCP servers only accept connections from this Mac.

- **Private by design.** FlightDeck sends no data anywhere. By default it makes no network requests at all; the exceptions are the opt-in latency probe (Settings › Network › Network quality), which pings your router and one host you choose, and the UniFi view, which talks only to the console you configure (and, while nothing is configured, checks whether your router looks like one). The Camera & Mic history records only that a device was in use, never audio
or video, and never leaves this Mac.

## Known limits

- Per-process network traffic comes from `/usr/bin/nettop`. Only that Apple binary holds the private
  network-statistics entitlement, so FlightDeck runs it once per sample (about 18 ms CPU) and diffs per-connection
  counters. A connection that opens and closes between two samples isn't counted. Against a 5 MB curl download
  the count came out at 5.01 MB (the extra is TLS overhead).
- Live CPU and GPU clocks come from IOReport (Performance › GPU › CPU clusters); Power & Freq shows the DVFS tables.
- Connections lists only your own processes' sockets, since `lsof` runs without root. The listening-ports panel would
  list every process's via `netstat`, but macOS gives an ad-hoc-signed app an empty socket table, so it falls back to
  your own processes (and says so).
- The Network, UPnP and Internet pages need macOS's Local Network permission. macOS ties that permission to the app's
  signature, and an ad-hoc-signed build gets a new one each time it's rebuilt, so a rebuilt copy may need to be allowed
  again (System Settings › Privacy & Security › Local Network). Without it the ARP table and Bonjour come back empty.
- Wi-Fi: congestion comes from one scan from this Mac's position: it sees which networks exist and how loud they are,
  not how busy they are, and the router may hear different neighbours. Without Location permission macOS also withholds
  beacon details, so wide channels are placed on the standard grid (2.4 GHz 40 MHz is assumed to extend away from the
  band edge, and 6 GHz 320 MHz is drawn on the 320-1 grid). macOS refreshes the link reading every 5 s, which sets the
  walk test's pace.
- No Mac can see which switch port or access point another device uses; the network map gets that only from a UniFi
  console.
- Thermal sensors refresh every 4 s, because reading all HID sensors costs about 70 ms. SMC keys outside the per-chip
  tables aren't read (an M1 Max has ~250; each read is an SMC round trip), so they don't appear under Other.
- The CPU speed limit comes from `pmset -g therm`, which runs only while Performance › Thermals is open, so throttling
  by the power manager is only seen (and only counted toward "time throttled") then; thermal pressure and the GPU
  heat cap are tracked all the time.

## Layout

- `Sources/FlightDeckCore`: samplers (CPU, memory, disk, network, power/thermal, processes), providers
  (system info, launchd, connections, apps, disk usage, frequency, benchmarks), and `Snapshot`/`Trace`.
- `Sources/FlightDeck`: the SwiftUI app. `Engine` owns sampling, history and recording/replay. The process
  table is an AppKit `NSOutlineView` updated by diffing, for low overhead.
- Cockpit and Ambient mode: the layout model (instrument kinds, sizes, layouts, JSON, grid packing, burn-in shift) is
  `FlightDeckCore/Cockpit.swift` and `CockpitStore.swift`, tested in `CockpitTests`; the views are `Views/Cockpit*.swift`
  (the page-digest instruments: `PageDigests*.swift` in FlightDeckCore, tested in `PageDigestTests`, fed by
  `CockpitFeeds.swift`)
  and `Views/AmbientView.swift`, the window is `AmbientWindow.swift`.

Automation hooks: `open build/FlightDeck.app --args -destination "Processes" -theme green -replayIndex 10`.

**Demo mode:** `open build/FlightDeck.app --args -demo YES -skipWelcome YES` runs the UI on synthetic data
(`Sources/FlightDeck/Demo.swift`) for screenshots. It never saves rules, never posts alerts and can't act on real
processes, run cleanups, start or stop services, or contact the network. The pages in the screenshots above (plus Console,
Checkup, which shows a placeholder, and Peripherals, which shows an invented desk) are synthetic. System Info, Connections, Installed Apps, Startup
Apps, Services, Users, the GPU tab and the process inspector still read this Mac, so don't screenshot those in demo mode. On Thermals every sensor (names and values), fan and pmset limit is invented, catalogued with the generic
Apple-silicon table so nothing depends on this Mac's chip. Camera & Mic shows invented sessions (Zoom, FaceTime, a
first use, an unknown app at 3 a.m. while locked) with no device listeners and nothing written. Restarts & Crashes shows
two invented months of boots with a thermal shutdown, a WindowServer watchdog panic and a slow login caused by an
invented sync app; it reads no records and writes no history.
