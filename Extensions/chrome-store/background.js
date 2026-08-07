// Fetchster Capture (Web Store) — hands browser downloads to the Fetchster
// menu bar app over Chrome native messaging. No host permissions needed.

const NATIVE_HOST = "com.fetchster.app";

// Cache the toggle so the cancel in onCreated doesn't wait on async storage.
let captureCache = true;
chrome.storage.local.get({ capture: true }, (stored) => {
  captureCache = stored.capture !== false;
});
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.capture) {
    captureCache = changes.capture.newValue !== false;
  }
});

function captureEnabled() {
  return captureCache;
}

function notify(title, message) {
  try {
    chrome.notifications.create({
      type: "basic",
      iconUrl: chrome.runtime.getURL("icons/icon128.png"),
      title,
      message,
    });
  } catch {
    // notifications unavailable — fine
  }
}

async function sendToApp(payload) {
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(NATIVE_HOST, payload, (response) => {
      const error = chrome.runtime.lastError;
      if (error) {
        resolve({ ok: false, error: error.message || "Fetchster is not running" });
        return;
      }
      resolve(response && typeof response === "object"
        ? response
        : { ok: false, error: "Invalid response from Fetchster" });
    });
  });
}

// Browser-initiated downloads: the browser owns the download until the
// user's save choice is known.
// - "Ask where to save" OFF: the browser picks a path immediately; onChanged
//   fires with that absolute filename and we hand it to the app.
// - "Ask where to save" ON: the native save panel appears; when the user picks
//   a folder and clicks Save, onChanged fires with that exact absolute path —
//   only then does the app start downloading, saving to the chosen location.
//   If the user clicks Cancel, nothing is downloaded.
const handedOffDownloads = new Set();

async function handOffToApp(item) {
  const payload = {
    url: item.url,
    filename: item.filename, // absolute path (browser default or user-chosen)
    userAgent: navigator.userAgent,
  };
  const result = await sendToApp(payload);
  if (result && result.ok) {
    // Handed off — cancel and erase the browser's copy.
    try {
      await chrome.downloads.cancel(item.id);
    } catch {
      // already finished
    }
    for (let attempt = 0; attempt < 5; attempt += 1) {
      try {
        const erased = await chrome.downloads.erase({ id: item.id });
        const count = Array.isArray(erased) ? erased.length : erased;
        if (count > 0) break;
      } catch {
        // item may still be finishing its cancel — retry shortly
      }
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    notify("Fetchster", `Downloading: ${result.title || item.filename}`);
    return true;
  }
  return false; // app not running — the browser download proceeds normally
}

// Poll a download until its save path is known, then hand it to the app.
// The path is set when the browser picks its default (no dialog) or when the
// user clicks Save in the native dialog — so the app always saves to the
// exact location the download is going to.
const pendingPolls = new Map();

function clearPoll(id) {
  const timer = pendingPolls.get(id);
  if (timer !== undefined) {
    clearTimeout(timer);
    pendingPolls.delete(id);
  }
}

function pollDownload(id, attemptsLeft) {
  if (attemptsLeft <= 0) {
    pendingPolls.delete(id);
    return;
  }
  chrome.downloads.search({ id }).then((items) => {
    const item = items && items[0];
    if (!item) {
      pendingPolls.delete(id);
      return;
    }
    if (item.state === "interrupted" || item.state === "canceled") {
      // User clicked Cancel (or the download was otherwise stopped) — nothing
      // to hand off.
      pendingPolls.delete(id);
      return;
    }
    if (item.filename && (item.state === "in_progress" || item.state === "complete")) {
      pendingPolls.delete(id);
      if (!handedOffDownloads.has(id)) {
        handedOffDownloads.add(id);
        handOffToApp(item);
      }
      return;
    }
    const timer = setTimeout(() => pollDownload(id, attemptsLeft - 1), 250);
    pendingPolls.set(id, timer);
  }).catch(() => {
    pendingPolls.delete(id);
  });
}

chrome.downloads.onCreated.addListener((item) => {
  if (!captureEnabled()) return;
  if (!item.url) return;
  const url = item.url;
  if (url.startsWith("blob:") || url.startsWith("data:")) return;
  if (handedOffDownloads.has(item.id)) return;

  if (item.filename && (item.state === "in_progress" || item.state === "complete")) {
    // The save path was already known (fast download while the worker woke).
    handedOffDownloads.add(item.id);
    handOffToApp(item);
    return;
  }

  // Otherwise poll (up to 15 minutes) until the save path appears.
  pollDownload(item.id, 15 * 60 * 4);
});

// Fast path when onChanged does fire (warm worker).
chrome.downloads.onChanged.addListener(async (delta) => {
  try {
    if (!captureEnabled()) return;
    const id = delta.id;
    if (!delta.filename || handedOffDownloads.has(id)) return;
    const found = await chrome.downloads.search({ id });
    const item = found && found[0];
    if (!item || !item.filename) return;
    if (item.state !== "in_progress" && item.state !== "complete") return;
    const url = item.url;
    if (url.startsWith("blob:") || url.startsWith("data:")) return;

    clearPoll(id);
    handedOffDownloads.add(id);
    const ok = await handOffToApp(item);
    if (!ok) {
      handedOffDownloads.delete(id);
    }
  } catch {
    // non-fatal
  }
});

// Right-click a link (works for magnet: and .torrent links too).
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "idl-download-link",
    title: "Download with Fetchster",
    contexts: ["link"],
  });
});

chrome.contextMenus.onClicked.addListener(async (info) => {
  if (info.menuItemId !== "idl-download-link" || !info.linkUrl) return;
  try {
    const result = await sendToApp({
      url: info.linkUrl,
      userAgent: navigator.userAgent,
    });
    notify(
      "Fetchster",
      result && result.ok ? "Added to Fetchster" : "Could not add to Fetchster"
    );
  } catch {
    notify("Fetchster", "Fetchster is not running — start it from the menu bar.");
  }
});

// Popup status checks (via the native messaging host).
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.type === "idl-ping") {
    sendToApp({ type: "ping" }).then((response) => sendResponse(response));
    return true;
  }
  return false;
});
