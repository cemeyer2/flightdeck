# Backlog

Requested features not built yet, newest last. Move an item to the README once it ships.

1. **UniFi integration.** When a UniFi network is detected (e.g. a UniFi gateway/console found by the network map, via
   its MAC vendor or SSDP/mDNS), or when the user configures a console by hand, connect to the UniFi console's API
   with the user's credentials or API key (stored in the Keychain) and pull its network metrics: clients and which
   AP/switch port each is on (real topology), per-client traffic, Wi-Fi signal and channel use, WAN throughput and
   latency, device health. Read-only, opt-in, and feeds the network map.