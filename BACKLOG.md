# Backlog

Requested features not built yet, newest last. Move an item to the README once it ships.

1. **Celsius / Fahrenheit.** A Settings choice for temperature units, applied everywhere temperatures appear
   (Summary, Thermals, Stress Map hub, fan explainer, Checkup, menu bar, CSV/PDF export labels).
2. **About screen.** Show the current version (from the bundle, as stamped by the release workflow), "by Charlie
   Meyer", and a credit to Claude.
4. **"System" theme.** A Theme option that follows macOS's light/dark appearance and switches live when it changes.
5. **Network map.** A flight deck for the local network: discover the devices on it and show each one's type,
   manufacturer, hostname, IP and MAC address (and anything else that can be learned), visually rather than as a list,
   ideally with the topology too (which devices connect through which routes).
7. **UniFi integration.** When a UniFi network is detected (e.g. a UniFi gateway/console found by the network map, via
   its MAC vendor or SSDP/mDNS), or when the user configures a console by hand, connect to the UniFi console's API
   with the user's credentials or API key (stored in the Keychain) and pull its network metrics: clients and which
   AP/switch port each is on (real topology), per-client traffic, Wi-Fi signal and channel use, WAN throughput and
   latency, device health. Read-only, opt-in, and feeds the network map.
8. **Disk Space shouldn't scan on a click.** Opening the Disk Space page (or an accidental click on it) starts a full
   recursive scan of the home folder, which is heavy and makes macOS ask for access to Downloads, Photos, Documents and
   so on. Scanning should only start when the user explicitly asks (a Scan button), with a note that macOS may ask for
   folder access.
