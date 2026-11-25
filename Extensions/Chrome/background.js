// FlightDeck Tabs: tells FlightDeck which tab runs in which Chrome renderer process. It only reports. Nothing FlightDeck
// sends makes it navigate, inject script, read page content or change a tab; the one message it accepts is "refresh",
// which re-sends the table. It never writes tab data to the console.
//
// Messages (protocol 1), sent to the native host app.flightdeck.chrome:
//   {type: "hello", protocol: 1, extensionVersion}
//   {type: "tabs", seq, tabs: [{tabId, windowId, active, audible, discarded, url, title, lastAccessed,
//                               frames: [{frameId, parentFrameId, processId, origin}]}]}
// A frame carries only its origin, never its full URL. Frames that have no process yet (processId < 0) and every frame
// of a discarded tab are left out.
//
// The app refuses a tab over its limits (URL 8192 bytes, title and origin 2048, 200 frames) and a table over 1000 tabs,
// and the host refuses a message over 2 MB, so everything is clipped below those here: strings by UTF-8 bytes, frames
// past the cap, and the least recently used tabs once the table would pass MAX_TABS or MAX_MESSAGE_BYTES.

const HOST = "app.flightdeck.chrome";
const PROTOCOL = 1;
const DEBOUNCE_MS = 1000;
const MAX_BACKOFF_MS = 300000;
const MAX_TABS = 900;
const MAX_FRAMES_PER_TAB = 150;
const MAX_URL_BYTES = 8000;
const MAX_TITLE_BYTES = 2000;
const MAX_ORIGIN_BYTES = 2000;
// Half the host's limit, as measured by jsonBytes, leaving room for anything Chrome's JSON writer escapes differently.
const MAX_MESSAGE_BYTES = 1000000;

let port = null;
let backoff = 1000;
let reconnectTimer = null;
let sendTimer = null;
let lastSent = 0;
let seq = 0;
let sending = false;
let sendAgain = false;

function connect() {
  reconnectTimer = null;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    port = null;
    scheduleReconnect();
    return;
  }
  port.onMessage.addListener((msg) => {
    backoff = 1000;
    if (msg && msg.type === "refresh") scheduleSend(true);
  });
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;   // read so Chrome doesn't report it as unchecked
    port = null;
    scheduleReconnect();
  });
  port.postMessage({ type: "hello", protocol: PROTOCOL, extensionVersion: chrome.runtime.getManifest().version });
  scheduleSend(true);
}

function scheduleReconnect() {
  if (reconnectTimer !== null) return;
  reconnectTimer = setTimeout(connect, backoff);
  backoff = Math.min(backoff * 2, MAX_BACKOFF_MS);
}

// At most one table per second: the first change after a quiet second goes out at once, later ones wait.
function scheduleSend(now) {
  if (sendTimer !== null) return;
  const wait = now ? 0 : Math.max(0, lastSent + DEBOUNCE_MS - Date.now());
  sendTimer = setTimeout(() => { sendTimer = null; sendTable(); }, wait);
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// At most maxBytes of UTF-8, cut at a character boundary (never inside a multi-byte sequence).
function clip(s, maxBytes) {
  const bytes = encoder.encode(s);
  if (bytes.length <= maxBytes) return s;
  let end = maxBytes;
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end -= 1;
  return decoder.decode(bytes.subarray(0, end));
}

// The UTF-8 size of v as JSON, counting "<", ">", "&", U+2028 and U+2029 at six bytes each in case Chrome writes them
// as \uXXXX escapes.
function jsonBytes(v) {
  const json = JSON.stringify(v);
  return encoder.encode(json).length + 5 * (json.match(/[<>&\u2028\u2029]/g) || []).length;
}

function originOf(url) {
  try { return new URL(url).origin; } catch (e) { return "null"; }
}

async function framesOf(tab) {
  if (tab.discarded) return [];
  let frames;
  try { frames = await chrome.webNavigation.getAllFrames({ tabId: tab.id }); } catch (e) { return []; }
  return (frames || [])
    .filter((f) => typeof f.processId === "number" && f.processId >= 0)
    .sort((a, b) => a.frameId - b.frameId)   // the main frame (0) first, so it survives the cap
    .slice(0, MAX_FRAMES_PER_TAB)
    .map((f) => ({ frameId: f.frameId, parentFrameId: f.parentFrameId, processId: f.processId,
                   origin: clip(originOf(f.url), MAX_ORIGIN_BYTES) }));
}

// One table at a time: a request that arrives while one is being built (the app's refresh right after connect, say)
// runs once more afterwards, so an older table is never posted after a newer one.
async function sendTable() {
  if (sending) { sendAgain = true; return; }
  sending = true;
  try { await buildAndPost(); } finally {
    sending = false;
    if (sendAgain) { sendAgain = false; scheduleSend(true); }
  }
}

async function buildAndPost() {
  if (port === null) return;
  lastSent = Date.now();
  let tabs;
  try { tabs = await chrome.tabs.query({}); } catch (e) { return; }
  const lastAccessedOf = (t) => (typeof t.lastAccessed === "number" ? t.lastAccessed : 0);
  // Most recently used first, so the tabs dropped past either cap are the ones used longest ago.
  const kept = tabs.filter((t) => typeof t.id === "number" && t.id >= 0)
    .sort((a, b) => lastAccessedOf(b) - lastAccessedOf(a))
    .slice(0, MAX_TABS);
  const built = await Promise.all(kept.map(async (t) => ({
    tabId: t.id,
    windowId: t.windowId,
    active: !!t.active,
    audible: !!t.audible,
    discarded: !!t.discarded,
    url: clip(t.url || "", MAX_URL_BYTES),
    title: clip(t.title || "", MAX_TITLE_BYTES),
    lastAccessed: lastAccessedOf(t),
    frames: await framesOf(t),
  })));
  const rows = [];
  let bytes = jsonBytes({ type: "tabs", seq: Number.MAX_SAFE_INTEGER, tabs: [] });
  for (const row of built) {
    const size = jsonBytes(row) + 1;   // and its comma
    if (bytes + size > MAX_MESSAGE_BYTES) break;
    bytes += size;
    rows.push(row);
  }
  if (port === null) return;
  seq += 1;
  try { port.postMessage({ type: "tabs", seq: seq, tabs: rows }); } catch (e) { /* disconnected meanwhile */ }
}

const changed = () => scheduleSend(false);
chrome.tabs.onCreated.addListener(changed);
chrome.tabs.onRemoved.addListener(changed);
chrome.tabs.onActivated.addListener(changed);
chrome.tabs.onUpdated.addListener((_tabId, info) => {
  if ("status" in info || "title" in info || "url" in info || "discarded" in info || "audible" in info) changed();
});
chrome.webNavigation.onCommitted.addListener(changed);
chrome.webNavigation.onCompleted.addListener(changed);
// Wakes the worker when Chrome starts, so the top-level connect() below runs without waiting for a tab event.
chrome.runtime.onStartup.addListener(() => {});

connect();
