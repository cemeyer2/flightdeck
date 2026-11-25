import Foundation
import CryptoKit
// Web dashboard, part 6: the page browsers load from `/`. One constant document with inline CSS and a single inline
// script, pinned in the Content-Security-Policy by its SHA-256 (computed here at runtime, so it can't drift from the
// script). The script only ever writes text through `textContent` and `setAttribute`, so an app or finding named like
// markup shows as that text. It loads nothing from anywhere else, reads only the fields of WebDashboardDocument it
// knows, and follows /api/stream: a `snapshot` event (with history) first, then one `sample` event per published
// sample. Colours are the app's Light and Dark palettes (Theme.swift).

public enum WebDashboardPage {
    public static let script: String = #"""
    'use strict';
    (function () {
      const S = { doc: null, hist: [], histEnd: 0, lastRecv: 0, up: false, backoff: 3000, retry: null };
      const $ = (id) => document.getElementById(id);

      function node(tag, cls, text) {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text !== undefined && text !== null) n.textContent = String(text);
        return n;
      }
      function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }
      function num(v, digits) { return Number(v).toLocaleString(undefined, { maximumFractionDigits: digits }); }
      function pct(v) { return num(v, v < 10 ? 1 : 0) + '%'; }
      function bytes(v) {
        const units = ['B', 'KB', 'MB', 'GB', 'TB'];
        let i = 0;
        while (Math.abs(v) >= 1000 && i < units.length - 1) { v /= 1000; i++; }
        return num(v, i === 0 ? 0 : (v < 10 ? 1 : 0)) + ' ' + units[i];
      }
      function rate(v) { return bytes(v) + '/s'; }
      function watts(v) { return num(v, v < 10 ? 1 : 0) + ' W'; }
      function celsius(v) { return num(v, 0) + ' °C'; }
      function rpm(v) { return num(v, 0) + ' rpm'; }
      function value(r) { return r && typeof r.value === 'number' ? r.value : null; }
      function duration(s) {
        if (s < 90) return Math.max(0, Math.round(s)) + ' s';
        if (s < 5400) return Math.round(s / 60) + ' min';
        if (s < 172800) return Math.round(s / 3600) + ' h';
        return Math.round(s / 86400) + ' days';
      }

      // A reading: its formatted value, or a dash with the reason as a tooltip and as visible small text.
      function put(id, r, fmt) {
        const slot = $(id);
        if (!slot) return;
        clear(slot);
        const v = value(r);
        if (v !== null) { slot.textContent = fmt(v); slot.removeAttribute('title'); return; }
        const why = (r && r.reason) || 'not reported';
        slot.appendChild(document.createTextNode('—'));
        slot.setAttribute('title', why);
        slot.appendChild(node('small', 'why', why));
      }
      function text(id, t) { const n = $(id); if (n) n.textContent = t; }

      function renderLights(lights) {
        const list = $('ann');
        clear(list);
        (lights || []).forEach((l) => {
          const li = node('li', 'lamp lvl-' + String(l.level || 'ok').replace(/[^a-z]/g, ''));
          li.appendChild(node('span', 'lbl', l.label));
          li.appendChild(node('span', 'lv', l.level || 'ok'));
          li.setAttribute('title', l.label + ': ' + (l.level || 'ok'));
          list.appendChild(li);
        });
      }

      function renderFindings(items, truncated) {
        const list = $('findings');
        clear(list);
        (items || []).forEach((f) => {
          const li = node('li', 'finding sev-' + String(f.severity || 'info').replace(/[^a-z]/g, ''));
          const head = node('p', 'ftitle');
          head.appendChild(node('strong', 'badge', String(f.severity || 'info').toUpperCase()));
          head.appendChild(document.createTextNode(' ' + (f.title || '')));
          li.appendChild(head);
          if (f.detail) li.appendChild(node('p', 'fdetail', f.detail));
          const since = Date.parse(f.since);
          if (!isNaN(since)) li.appendChild(node('small', 'fsince', 'for ' + duration((Date.now() - since) / 1000)));
          list.appendChild(li);
        });
        $('no-findings').hidden = (items || []).length > 0;
        $('findings-more').hidden = !truncated;
      }

      function renderReadings(r) {
        r = r || {};
        put('r-cpu', r.cpu_percent, pct);
        put('r-gpu', r.gpu_percent, pct);
        put('r-pressure', r.memory_pressure_percent, pct);
        put('r-used', r.memory_used_bytes, bytes);
        put('r-total', r.memory_total_bytes, bytes);
        put('r-swap', r.swap_bytes, bytes);
        put('r-hot', r.hottest_c, celsius);
        text('r-thermal', r.thermal_state ? r.thermal_state : '—');
        put('r-fan', r.fan_rpm, rpm);
        put('r-read', r.disk_read_bytes_per_s, rate);
        put('r-write', r.disk_write_bytes_per_s, rate);
        put('r-free', r.disk_free_bytes, bytes);
        put('r-in', r.net_in_bytes_per_s, rate);
        put('r-out', r.net_out_bytes_per_s, rate);
        put('r-watts', r.system_watts, watts);
        put('r-battery', r.battery_percent, pct);
        text('r-charging', r.charging === true ? 'charging' : r.charging === false ? 'not charging' : '');
      }

      function renderApps(apps, truncated) {
        const body = $('apps');
        clear(body);
        (apps || []).forEach((a) => {
          const tr = node('tr');
          const name = node('th', 'app', a.name);
          name.setAttribute('scope', 'row');
          if (a.count > 1) name.appendChild(node('small', 'count', ' ×' + a.count));
          tr.appendChild(name);
          tr.appendChild(node('td', 'n', typeof a.cpu_percent === 'number' ? pct(a.cpu_percent) : '—'));
          tr.appendChild(node('td', 'n', typeof a.memory_bytes === 'number' ? bytes(a.memory_bytes) : '—'));
          tr.appendChild(node('td', 'n', typeof a.energy_watts === 'number' ? watts(a.energy_watts) : '—'));
          body.appendChild(tr);
        });
        $('no-apps').hidden = (apps || []).length > 0;
        $('apps-more').hidden = !truncated;
      }

      // Gap points and missing values lift the pen (a new M), so a hole is never bridged.
      function spark(id, key, lo, hi) {
        const path = $(id);
        if (!path) return;
        const pts = S.hist, n = pts.length;
        const vals = pts.map((p) => (p && !p.gap && typeof p[key] === 'number' && isFinite(p[key])) ? p[key] : null);
        let min = lo, max = hi;
        if (min === null || max === null) {
          const real = vals.filter((v) => v !== null);
          if (!real.length) { path.setAttribute('d', ''); return; }
          min = Math.min.apply(null, real) - 2; max = Math.max.apply(null, real) + 2;
          if (max - min < 10) { const mid = (max + min) / 2; min = mid - 5; max = mid + 5; }
        }
        let d = '', pen = false;
        vals.forEach((v, i) => {
          if (v === null) { pen = false; return; }
          const x = n > 1 ? i * 120 / (n - 1) : 120;
          const y = 29 - (Math.min(Math.max(v, min), max) - min) / ((max - min) || 1) * 27;
          d += (pen ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1) + ' ';
          pen = true;
        });
        path.setAttribute('d', d.trim());
      }
      function renderSparks() {
        spark('s-cpu', 'cpu_percent', 0, 100);
        spark('s-mem', 'memory_percent', 0, 100);
        spark('s-hot', 'hottest_c', null, null);
        $('hist-note').hidden = !S.histNote;
        text('hist-note', S.histNote || '');
      }

      // Each sample replaces the newest 30 s bucket, or starts a new one; buckets skipped meanwhile become gaps.
      function addPoint(p) {
        const t = Date.parse(p.t);
        if (isNaN(t)) return;
        if (!S.hist.length || !S.histEnd) { S.hist = [p]; S.histEnd = t; return; }
        let guard = 0;
        while (t > S.histEnd && guard < 60) {
          S.histEnd += 30000; guard++;
          S.hist.push({ t: new Date(S.histEnd).toISOString(), gap: true });
          if (S.hist.length > 60) S.hist.shift();
        }
        if (t > S.histEnd) S.histEnd = t;
        S.hist[S.hist.length - 1] = p;
      }

      function render(d) {
        S.doc = d;
        S.lastRecv = Date.now();
        const mac = d.mac || {};
        text('name', mac.name || 'Mac');
        document.title = (mac.name || 'Mac') + ' · FlightDeck';
        $('demo').hidden = d.demo !== true;
        text('about', [mac.macos ? 'macOS ' + mac.macos : '', mac.app ? 'FlightDeck ' + mac.app : '',
                       typeof mac.uptime_s === 'number' ? 'up ' + duration(mac.uptime_s) : ''].filter(Boolean).join(' · '));
        renderLights(d.annunciator);
        renderFindings(d.findings, d.findings_truncated === true);
        renderReadings(d.readings);
        renderApps(d.top_apps, d.top_apps_truncated === true);
        renderSparks();
        tick();
      }

      function tick() {
        const d = S.doc, msgs = [];
        if (!S.up) msgs.push('Reconnecting…');
        // Ages use this device's clock from when an event arrived, since the phone's clock may not match the Mac's.
        const age = (Date.now() - S.lastRecv) / 1000;
        if (d) {
          if (d.sampling === 'paused') msgs.push('Sampling paused on the Mac');
          else if (!d.sampled_at) msgs.push('Waiting for the first sample…');
          else if (S.up && age > 3 * (d.interval_s || 1)) msgs.push('No update for ' + Math.round(age) + ' s');
          if (d.interval_s >= 5) msgs.push('updated every ' + num(d.interval_s, 0) + ' s while FlightDeck is in the background');
          text('ago', d.sampled_at ? 'updated ' + duration(age) + ' ago' : '');
        }
        const status = $('status');
        status.textContent = msgs.join(' · ');
        status.hidden = msgs.length === 0;
        document.body.classList.toggle('offline', !S.up);
        $('live').classList.toggle('on', S.up);
        text('live-text', S.up ? 'live' : 'offline');
      }

      function parse(data) { try { return JSON.parse(data); } catch (e) { return null; } }

      // A closed EventSource exposes no response headers, so a 429's Retry-After (10 s) is honoured only through this
      // backoff: 3 s, then doubling up to 60 s (past the server's 10 s by the third try), reset by each snapshot.
      function later() {
        if (S.retry) return;
        S.retry = setTimeout(connect, S.backoff);
        S.backoff = Math.min(S.backoff * 2, 60000);
      }

      function connect() {
        S.retry = null;
        const es = new EventSource('/api/stream');
        es.addEventListener('snapshot', (ev) => {
          const d = parse(ev.data);
          if (!d) return;
          S.up = true; S.backoff = 3000;
          S.hist = Array.isArray(d.history) ? d.history.slice(-60) : [];
          S.histNote = d.history_unavailable || '';
          const last = S.hist.length ? Date.parse(S.hist[S.hist.length - 1].t) : NaN;
          S.histEnd = isNaN(last) ? 0 : last;
          render(d);
        });
        es.addEventListener('sample', (ev) => {
          const d = parse(ev.data);
          if (!d) return;
          S.up = true;
          if (d.point) addPoint(d.point);
          render(d);
        });
        es.addEventListener('error', () => {
          S.up = false;
          tick();
          if (es.readyState === EventSource.CLOSED) { es.close(); later(); }
        });
      }

      setInterval(tick, 1000);
      tick();
      connect();
    })();
    """#

    public static let scriptHash: String = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()

    public static var csp: String {
        "default-src 'none'; script-src 'sha256-\(scriptHash)'; style-src 'unsafe-inline'; img-src 'self' data:; "
            + "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    }

    static let head = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="referrer" content="no-referrer">
    <title>FlightDeck</title>
    <link rel="icon" href="/favicon.svg" type="image/svg+xml">
    <style>
    :root { --bg: #f2f2f5; --panel: #ffffff; --border: rgba(0,0,0,0.08); --text: #1a1a1a; --dim: #737373;
            --accent: #007ad9; --accent2: #d95a1a; --warn: #c96a00; --warnfill: #ff9500; --crit: #d70015; --critfill: #ff3b30;
            --info: rgba(0,122,217,0.18); --grid: rgba(0,0,0,0.06); color-scheme: light dark; }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #121417; --panel: #1c1f21; --border: rgba(255,255,255,0.07); --text: #ebebeb; --dim: #8c8c8c;
              --accent: #40c7ff; --accent2: #ff8c40; --warn: #ff9f0a; --warnfill: #ff9f0a; --crit: #ff4d4d; --critfill: #ff4d4d;
              --info: rgba(64,199,255,0.25); --grid: rgba(255,255,255,0.06); }
    }
    * { box-sizing: border-box; }
    html { -webkit-text-size-adjust: 100%; }
    body { margin: 0; background: var(--bg); color: var(--text); font: 1rem/1.4 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
    main { max-width: 1100px; margin: 0 auto; padding: 0.75rem 1rem 2rem; }
    header { display: flex; flex-wrap: wrap; align-items: baseline; gap: 0.25rem 0.75rem; padding: 0.5rem 0; }
    h1 { font-size: 1.5rem; margin: 0; overflow-wrap: anywhere; }
    h2 { font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--dim); margin: 1.25rem 0 0.5rem; }
    h3 { font-size: 0.85rem; margin: 0; color: var(--dim); font-weight: 600; }
    .live { font-size: 0.85rem; color: var(--dim); display: inline-flex; align-items: center; gap: 0.35rem; }
    .dot { width: 0.6rem; height: 0.6rem; border-radius: 50%; background: var(--dim); display: inline-block; }
    .dot.on { background: #34c759; }
    #ago, .about { font-size: 0.85rem; color: var(--dim); }
    .about { margin: 0; }
    .banner { background: var(--warnfill); color: #000; font-weight: 700; padding: 0.4rem 0.75rem; border-radius: 6px; margin: 0.5rem 0; }
    .status { background: var(--panel); border: 1px solid var(--border); border-radius: 6px; padding: 0.4rem 0.75rem; font-size: 0.9rem; margin: 0.5rem 0; }
    .ann { list-style: none; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.35rem; }
    .lamp { background: var(--panel); border: 1px solid var(--border); border-radius: 4px; padding: 0.3rem 0.2rem; text-align: center;
            font: 700 0.75rem/1.2 ui-monospace, Menlo, monospace; }
    .lamp .lbl { display: block; }
    .lamp .lv { display: block; font-size: 0.6rem; font-weight: 400; color: var(--dim); }
    .lamp.lvl-ok .lbl { color: var(--dim); }
    .lamp.lvl-info { background: var(--info); }
    .lamp.lvl-caution { background: var(--warnfill); border-color: var(--warnfill); color: #000; }
    .lamp.lvl-warning { background: var(--critfill); border-color: var(--critfill); color: #000; }
    .lamp.lvl-caution .lv, .lamp.lvl-warning .lv { color: #000; }
    ul.list { list-style: none; margin: 0; padding: 0; }
    .finding { background: var(--panel); border: 1px solid var(--border); border-left: 4px solid var(--accent); border-radius: 6px;
               padding: 0.5rem 0.75rem; margin-bottom: 0.4rem; }
    .finding.sev-caution { border-left-color: var(--warnfill); }
    .finding.sev-warning { border-left-color: var(--critfill); }
    .finding p { margin: 0; overflow-wrap: anywhere; }
    .badge { font-size: 0.65rem; letter-spacing: 0.05em; color: var(--dim); }
    .sev-caution .badge { color: var(--warn); }
    .sev-warning .badge { color: var(--crit); }
    .fdetail { color: var(--dim); font-size: 0.9rem; }
    .fsince { color: var(--dim); font-size: 0.75rem; }
    .empty { color: var(--dim); margin: 0; }
    .tiles { display: grid; grid-template-columns: 1fr; gap: 0.5rem; }
    .tile { background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 0.6rem 0.75rem; min-width: 0; }
    .big { font: 600 1.6rem/1.2 ui-monospace, Menlo, monospace; margin: 0.15rem 0; overflow-wrap: anywhere; }
    .sub { margin: 0; font-size: 0.85rem; color: var(--dim); overflow-wrap: anywhere; }
    .sub span, .big span { color: var(--text); }
    .why { display: block; font: 400 0.7rem/1.3 -apple-system, sans-serif; color: var(--dim); }
    svg.spark { display: block; width: 100%; height: 2.25rem; margin-top: 0.35rem; background: var(--grid); border-radius: 3px; }
    svg.spark path { fill: none; stroke: var(--accent); stroke-width: 1.5; vector-effect: non-scaling-stroke; stroke-linejoin: round; }
    .note { color: var(--dim); font-size: 0.8rem; margin: 0.35rem 0 0; }
    table { width: 100%; border-collapse: collapse; background: var(--panel); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
    th, td { padding: 0.4rem 0.6rem; text-align: left; border-bottom: 1px solid var(--border); }
    thead th { font-size: 0.75rem; color: var(--dim); font-weight: 600; }
    tbody th { font-weight: 500; overflow-wrap: anywhere; }
    td.n, thead th.n { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
    .count { color: var(--dim); }
    footer { color: var(--dim); font-size: 0.8rem; margin-top: 1.5rem; }
    body.offline .tiles, body.offline table, body.offline .ann { opacity: 0.45; filter: grayscale(1); }
    [hidden] { display: none !important; }
    @media (min-width: 601px) {
      .ann { grid-template-columns: repeat(6, 1fr); }
      .tiles { grid-template-columns: repeat(auto-fill, minmax(15rem, 1fr)); }
      .cols { display: grid; grid-template-columns: 1fr 1fr; gap: 0 1.25rem; align-items: start; }
    }
    @media (min-width: 1000px) { .tiles { grid-template-columns: repeat(3, 1fr); } }
    </style>
    </head>
    <body>
    <main>
    <header>
      <h1 id="name">FlightDeck</h1>
      <span class="live"><span id="live" class="dot" aria-hidden="true"></span><span id="live-text">connecting</span></span>
      <span id="ago"></span>
    </header>
    <p class="about" id="about"></p>
    <div id="demo" class="banner" hidden>Demo data</div>
    <div id="status" class="status" role="status" aria-live="polite" hidden></div>

    <section aria-labelledby="h-ann">
      <h2 id="h-ann">Annunciator</h2>
      <ul id="ann" class="ann"></ul>
    </section>

    <section aria-labelledby="h-findings">
      <h2 id="h-findings">Findings</h2>
      <ul id="findings" class="list"></ul>
      <p id="no-findings" class="empty">Nothing needs attention.</p>
      <p id="findings-more" class="note" hidden>More findings on the Mac.</p>
    </section>

    <section aria-labelledby="h-readings">
      <h2 id="h-readings">Readings</h2>
      <div class="tiles">
        <article class="tile"><h3>CPU</h3><p class="big"><span id="r-cpu">—</span></p><p class="sub">GPU <span id="r-gpu">—</span></p>
          <svg class="spark" viewBox="0 0 120 30" preserveAspectRatio="none" aria-hidden="true"><path id="s-cpu" d=""/></svg></article>
        <article class="tile"><h3>Memory</h3><p class="big"><span id="r-pressure">—</span></p>
          <p class="sub">pressure · used <span id="r-used">—</span> of <span id="r-total">—</span> · swap <span id="r-swap">—</span></p>
          <svg class="spark" viewBox="0 0 120 30" preserveAspectRatio="none" aria-hidden="true"><path id="s-mem" d=""/></svg></article>
        <article class="tile"><h3>Thermals</h3><p class="big"><span id="r-hot">—</span></p>
          <p class="sub">hottest sensor · <span id="r-thermal">—</span> · fan <span id="r-fan">—</span></p>
          <svg class="spark" viewBox="0 0 120 30" preserveAspectRatio="none" aria-hidden="true"><path id="s-hot" d=""/></svg></article>
        <article class="tile"><h3>Disk</h3><p class="big"><span id="r-read">—</span></p>
          <p class="sub">read · write <span id="r-write">—</span> · free <span id="r-free">—</span></p></article>
        <article class="tile"><h3>Network</h3><p class="big"><span id="r-in">—</span></p><p class="sub">in · out <span id="r-out">—</span></p></article>
        <article class="tile"><h3>Energy</h3><p class="big"><span id="r-watts">—</span></p><p class="sub">whole system</p></article>
        <article class="tile"><h3>Battery</h3><p class="big"><span id="r-battery">—</span></p><p class="sub"><span id="r-charging"></span></p></article>
      </div>
      <p id="hist-note" class="note" hidden></p>
    </section>

    <section aria-labelledby="h-apps">
      <h2 id="h-apps">Top apps</h2>
      <table>
        <thead><tr><th scope="col">App</th><th scope="col" class="n">CPU</th><th scope="col" class="n">Memory</th><th scope="col" class="n">Energy</th></tr></thead>
        <tbody id="apps"></tbody>
      </table>
      <p id="no-apps" class="empty" hidden>No apps reported yet.</p>
      <p id="apps-more" class="note" hidden>More apps on the Mac.</p>
    </section>

    <footer>Read-only view from FlightDeck. Nothing can be changed from this page. Sparklines cover the last 30 minutes.</footer>
    </main>
    """#

    static let tail = "\n</body>\n</html>\n"

    /// The whole page: markup, then the one script (its exact text is what `scriptHash` covers).
    public static let html: String = head + "\n<script>" + script + "</script>" + tail

    /// A small gauge; no external references.
    public static let favicon = #"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><circle cx="16" cy="16" r="15" fill="#121417"/><path d="M6.5 21a10 10 0 1 1 19 0" fill="none" stroke="#40c7ff" stroke-width="3" stroke-linecap="round"/><path d="M16 20 22 11" stroke="#ff9f0a" stroke-width="2.5" stroke-linecap="round"/><circle cx="16" cy="20" r="2.2" fill="#ebebeb"/></svg>
    """#
}
