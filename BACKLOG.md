# Backlog

Requested features not built yet, newest last. Move an item to the README once it ships.

1. **Celsius / Fahrenheit.** A Settings choice for temperature units, applied everywhere temperatures appear
   (Summary, Thermals, Stress Map hub, fan explainer, Checkup, menu bar, CSV/PDF export labels).
2. **About screen.** Show the current version (from the bundle, as stamped by the release workflow), "by Charlie
   Meyer", and a credit to Claude.
3. **MCP server.** Expose FlightDeck's data to AI assistants (Claude Code, Codex and others) over the Model Context
   Protocol: e.g. tools for current findings, top processes, a process's details and stacks, recent incidents, and
   black-box replays. Opt-in, local only, like the Prometheus endpoint.
4. **"System" theme.** A Theme option that follows macOS's light/dark appearance and switches live when it changes.
5. **Network map.** A flight deck for the local network: discover the devices on it and show each one's type,
   manufacturer, hostname, IP and MAC address (and anything else that can be learned), visually rather than as a list,
   ideally with the topology too (which devices connect through which routes).
6. **UPnP map / browser.** Discover UPnP/SSDP devices (M-SEARCH on the local network), read their device descriptions
   (friendly name, manufacturer, model, device type, services) and show them browsable, including any port mappings
   the router's UPnP IGD has opened, so it's clear which apps punched holes through the router.
