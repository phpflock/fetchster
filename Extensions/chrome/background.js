// Fetchster Capture — hands browser downloads to the Fetchster menu bar app
// (local control server on 127.0.0.1:8765) with the browser's own headers.

const SERVER = "http://127.0.0.1:8765";

// URL -> latest observed request metadata.
const headerCache = new Map();
const CACHE_LIMIT = 256;

chrome.webRequest.onSendHeaders.addListener(
  (details) => {
    if (!details.requestHeaders) return;
    const all = {};
    let userAgent = "";
    let referer = "";
    let cookie = "";
    for (const header of details.requestHeaders) {
      const name = (header.name || "").toLowerCase();
      all[header.name] = header.value;
      if (name === "user-agent") userAgent = header.value || "";
      else if (name === "referer") referer = header.value || "";
      else if (name === "cookie") cookie = header.value || "";
    }
    headerCache.set(details.url, { userAgent, referer, cookie, headers: all });
    if (headerCache.size > CACHE_LIMIT) {
      headerCache.delete(headerCache.keys().next().value);
    }
  },
  { urls: ["<all_urls>"] },
  ["requestHeaders"]
);

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

async function cookiesFor(url) {
  try {
    const cookies = await chrome.cookies.getAll({ url });
    return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch {
    return "";
  }
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
  const response = await fetch(`${SERVER}/api/download`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  return response.json();
}

// Arbitrary file links: the browser owns the download until the user's save
// choice is known.
// - "Ask where to save" OFF: the browser picks a path immediately; onChanged
//   fires with that absolute filename and we hand it to the app.
// - "Ask where to save" ON: the native save panel appears; when the user picks
//   a folder and clicks Save, onChanged fires with that exact absolute path —
//   only then does the app start downloading, saving to the chosen location.
//   If the user clicks Cancel, nothing is downloaded.
const handedOffDownloads = new Set();

async function handOffToApp(item) {
  const url = item.url;
  const info = headerCache.get(url) || {};
  const payload = {
    url,
    filename: item.filename, // absolute path (browser default or user-chosen)
    userAgent: info.userAgent || navigator.userAgent,
    referer: info.referer,
    cookies: info.cookie || (await cookiesFor(url)),
    headers: info.headers || undefined,
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
    // Firefox doesn't implement downloads.get; search is supported everywhere.
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
    const cookies = await cookiesFor(info.linkUrl);
    const result = await sendToApp({
      url: info.linkUrl,
      userAgent: navigator.userAgent,
      cookies,
    });
    notify(
      "Fetchster",
      result && result.ok ? "Added to Fetchster" : "Could not add to Fetchster"
    );
  } catch {
    notify("Fetchster", "Fetchster is not running — start it from the menu bar.");
  }
});

// Click-level captures from content.js (magnet:, .torrent, download attribute).
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.type === "idl-browser") {
    browserName = message.name || "chrome";
    sendResponse({ ok: true });
    return false;
  }
  if (message && message.type === "idl-media-manifest") {
    const tabId = sender.tab ? sender.tab.id : -1;
    if (tabId >= 0 && message.url && message.body) {
      let bodies = manifestBodies.get(tabId);
      if (!bodies) {
        bodies = new Map();
        manifestBodies.set(tabId, bodies);
      }
      bodies.set(message.url, { contentType: message.contentType, body: message.body });

      const kind = streamKind(message.url, message.contentType || "");
      if (kind) {
        let tabMedia = mediaByTab.get(tabId);
        if (!tabMedia) {
          tabMedia = new Map();
          mediaByTab.set(tabId, tabMedia);
        }
        tabMedia.set(message.url, {
          url: message.url,
          mime: undefined,
          size: undefined,
          label: undefined,
          kind: kind === "direct" ? "dash" : kind,
        });
        scheduleMediaSend(tabId);
      }
    }
    sendResponse({ ok: true });
    return false;
  }
  if (message && message.type === "idl-media-element") {
    const tabId = sender.tab ? sender.tab.id : -1;
    if (tabId >= 0 && message.url) {
      let tabMedia = mediaByTab.get(tabId);
      if (!tabMedia) {
        tabMedia = new Map();
        mediaByTab.set(tabId, tabMedia);
      }
      if (!tabMedia.has(message.url)) {
        tabMedia.set(message.url, {
          url: message.url,
          mime: undefined,
          size: undefined,
          label: undefined,
          kind: streamKind(message.url, ""),
        });
        scheduleMediaSend(tabId);
      }
    }
    sendResponse({ ok: true });
    return false;
  }
  if (!message || message.type !== "idl-capture") return false;

  (async () => {
    let response = { ok: false };
    try {
      if (await captureEnabled()) {
        const cookies = await cookiesFor(message.url);
        response = await sendToApp({
          url: message.url,
          filename: message.title || undefined,
          userAgent: navigator.userAgent,
          referer: message.referer,
          cookies,
        });
        if (response.ok) {
          notify("Fetchster", `Downloading: ${response.title || message.url}`);
        }
      }
    } catch {
      // app not running — let the browser behave normally next time
    }
    sendResponse(response);
  })();

  return true; // keep the service worker alive until sendResponse
});

// ===== Video detection =====
// Watches media responses so the app can list every playable stream on the
// page (format + size) and download it with the browser's exact headers.

const mediaByTab = new Map(); // tabId -> Map(url -> stream info)
const mediaTimers = new Map(); // tabId -> debounce timer
const tabPages = new Map(); // tabId -> page URL (for clearing stale media)
const manifestBodies = new Map(); // tabId -> Map(url -> {contentType, body})
let browserName = "chrome"; // set by content.js (idl-browser)
const VIDEO_EXT = /\.(mp4|webm|mkv|mov|avi|m4v|flv|wmv|mpg|mpeg|3gp|ogv|ts)$/i;

// Classify a media URL into what the app can download.
// "hls"  -> playlist assembled by ffmpeg
// "dash" -> manifest (YouTube included); segments downloaded + muxed
// "direct" -> plain video file
function streamKind(url, contentType) {
  if (url.startsWith("blob:") || url.startsWith("data:")) return null;
  const lower = url.toLowerCase();
  if (lower.endsWith(".m3u8") || contentType.startsWith("application/vnd.apple.mpegurl")
      || contentType.startsWith("application/x-mpegurl")) {
    return "hls";
  }
  if (lower.endsWith(".mpd") || contentType.startsWith("application/dash+xml")
      || contentType.includes("yt-ump")) {
    return "dash";
  }
  if (contentType.startsWith("video/")) return "direct";
  if (contentType.startsWith("application/octet-stream") && VIDEO_EXT.test(lower)) return "direct";
  return null;
}

function headerValue(headers, name) {
  for (const h of headers || []) {
    if ((h.name || "").toLowerCase() === name) return h.value || "";
  }
  return "";
}

chrome.webRequest.onHeadersReceived.addListener(
  (details) => {
    if (details.tabId < 0) return;
    const contentType = headerValue(details.responseHeaders, "content-type").toLowerCase();
    const kind = streamKind(details.url, contentType);
    if (!kind) return;

    let tabMedia = mediaByTab.get(details.tabId);
    if (!tabMedia) {
      tabMedia = new Map();
      mediaByTab.set(details.tabId, tabMedia);
    }
    const length = headerValue(details.responseHeaders, "content-length");
    const size = length && /^\d+$/.test(length) ? parseInt(length, 10) : undefined;
    tabMedia.set(details.url, {
      url: details.url,
      mime: contentType.startsWith("video/") ? contentType : undefined,
      size,
      label: undefined,
      kind,
    });
    scheduleMediaSend(details.tabId);
  },
  { urls: ["<all_urls>"], types: ["media", "xmlhttprequest", "other"] },
  ["responseHeaders"]
);

function scheduleMediaSend(tabId) {
  const existing = mediaTimers.get(tabId);
  if (existing) clearTimeout(existing);
  mediaTimers.set(
    tabId,
    setTimeout(() => {
      mediaTimers.delete(tabId);
      sendMediaForTab(tabId);
    }, 250)
  );
}

async function sendMediaForTab(tabId) {
  const tabMedia = mediaByTab.get(tabId);
  const bodies = manifestBodies.get(tabId);
  const streams = [];
  if (tabMedia) {
    for (const stream of tabMedia.values()) {
      const info = headerCache.get(stream.url) || {};
      const manifest = bodies ? bodies.get(stream.url) : undefined;
      streams.push({
        url: stream.url,
        mime: stream.mime,
        size: stream.size,
        label: stream.label,
        referer: info.referer,
        userAgent: info.userAgent || navigator.userAgent,
        cookies: info.cookie || (await cookiesFor(stream.url)),
        kind: stream.kind,
        manifestBody: manifest ? manifest.body : undefined,
      });
    }
  }
  let pageTitle = "";
  let pageURL = "";
  try {
    const tab = await chrome.tabs.get(tabId);
    pageTitle = tab.title || "";
    pageURL = tab.url || "";
    tabPages.set(tabId, pageURL);
  } catch {
    // tab is gone — clear by the last known page URL
    pageURL = tabPages.get(tabId) || "";
  }
  try {
    await fetch(`${SERVER}/api/media`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ pageTitle, pageURL, browser: browserName, streams }),
    });
  } catch {
    // app not running — nothing to do
  }
}

// Switching tabs shows that tab's streams in the app.
chrome.tabs.onActivated.addListener((info) => {
  sendMediaForTab(info.tabId);
});

// Tab closed: clear its streams from the app.
chrome.tabs.onRemoved.addListener((tabId) => {
  const pageURL = tabPages.get(tabId) || "";
  if (pageURL) {
    fetch(`${SERVER}/api/media`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ pageTitle: "", pageURL, streams: [] }),
    }).catch(() => {});
  }
  mediaByTab.delete(tabId);
  manifestBodies.delete(tabId);
  tabPages.delete(tabId);
  const timer = mediaTimers.get(tabId);
  if (timer) {
    clearTimeout(timer);
    mediaTimers.delete(tabId);
  }
});

// New page in a tab: previous streams are gone.
chrome.webNavigation.onCommitted.addListener((details) => {
  if (details.frameId !== 0) return;
  const previous = tabPages.get(details.tabId);
  mediaByTab.delete(details.tabId);
  manifestBodies.delete(details.tabId);
  if (previous && previous !== details.url) {
    fetch(`${SERVER}/api/media`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ pageTitle: "", pageURL: previous, streams: [] }),
    }).catch(() => {});
  }
  tabPages.set(details.tabId, details.url);
  const timer = mediaTimers.get(details.tabId);
  if (timer) {
    clearTimeout(timer);
    mediaTimers.delete(details.tabId);
  }
});
