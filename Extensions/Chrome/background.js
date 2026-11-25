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

const HOST = "app.flightdeck.chrome";
const PROTOCOL = 1;
const DEBOUNCE_MS = 1000;
const MAX_BACKOFF_MS = 300000;

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

function originOf(url) {
  try { return new URL(url).origin; } catch (e) { return "null"; }
}

async function framesOf(tab) {
  if (tab.discarded) return [];
  let frames;
  try { frames = await chrome.webNavigation.getAllFrames({ tabId: tab.id }); } catch (e) { return []; }
  return (frames || [])
    .filter((f) => typeof f.processId === "number" && f.processId >= 0)
    .map((f) => ({ frameId: f.frameId, parentFrameId: f.parentFrameId, processId: f.processId, origin: originOf(f.url) }));
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
  const rows = await Promise.all(tabs.filter((t) => typeof t.id === "number" && t.id >= 0).map(async (t) => ({
    tabId: t.id,
    windowId: t.windowId,
    active: !!t.active,
    audible: !!t.audible,
    discarded: !!t.discarded,
    url: t.url || "",
    title: t.title || "",
    lastAccessed: typeof t.lastAccessed === "number" ? t.lastAccessed : 0,
    frames: await framesOf(t),
  })));
  if (port === null) return;
  seq += 1;
  try { port.postMessage({ type: "tabs", seq: seq, tabs: rows }); } catch (e) { /* disconnected meanwhile */ }
}

const changed = () => scheduleSend(false);
chrome.tabs.onCreated.addListener(changed);
chrome.tabs.onRemoved.addListener(changed);
chrome.tabs.onActivated.addListener(changed);
chrome.tabs.onUpdated.addListener((tabId, info) => {
  if ("status" in info || "title" in info || "url" in info || "discarded" in info || "audible" in info) changed();
});
chrome.webNavigation.onCommitted.addListener(changed);
chrome.webNavigation.onCompleted.addListener(changed);
// Wakes the worker when Chrome starts, so the top-level connect() below runs without waiting for a tab event.
chrome.runtime.onStartup.addListener(() => {});

connect();
