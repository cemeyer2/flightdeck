# Backlog

Requested features not built yet, newest last. Move an item to the README once it ships.

- **Say what time span every graph shows.** Many graphs don't say whether they cover the last minute, ten minutes
  or an hour (e.g. Summary's CPU, Memory, Thermals and GPU cards). The span isn't fixed: the cockpit draws the last
  120 samples, so it is about 2 min at the default 1 s interval, longer while sampling slows in the background, and
  whatever the recording's interval is in replay. Audit every visualization (cockpit, Ambient, page charts, Trends,
  web dashboard) and label each with the span its data actually covers, worked out from the samples rather than
  assumed.
