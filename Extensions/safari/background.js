// Fetchster Safari — background page.
// Talks to the Fetchster app through Safari native messaging
// (browser.runtime.sendNativeMessage -> SafariWebExtensionHandler).

const NATIVE_HOST = "com.fetchster.app";

function nativeCall(payload) {
  return new Promise((resolve) => {
    try {
      browser.runtime.sendNativeMessage(NATIVE_HOST, payload, (response) => {
        const error = browser.runtime.lastError;
        if (error) {
          resolve({ ok: false, error: String(error.message || error) });
          return;
        }
        resolve(response && typeof response === "object"
          ? response
          : { ok: false, error: "Invalid response from Fetchster" });
      });
    } catch (e) {
      resolve({ ok: false, error: String((e && e.message) || e) });
    }
  });
}

function notify(title, message) {
  try {
    if (browser.notifications && browser.notifications.create) {
      browser.notifications.create({
        type: "basic",
        iconUrl: browser.runtime.getURL("icons/icon128.png"),
        title,
        message,
      });
    }
  } catch {
    // notifications unavailable — fine
  }
}

function videoIdFromURL(urlString) {
  try {
    const url = new URL(urlString);
    const v = url.searchParams.get("v");
    if (v) return v;
    if (url.hostname === "youtu.be") {
      const id = url.pathname.slice(1);
      if (id) return id;
    }
  } catch {}
  return null;
}

function createMenus() {
  browser.contextMenus.create({
    id: "fetchster-link",
    title: "Download with Fetchster",
    contexts: ["link"],
  });
  browser.contextMenus.create({
    id: "fetchster-page",
    title: "Download with Fetchster",
    contexts: ["page"],
  });
}

try {
  createMenus();
} catch {
  // created from onInstalled below
}
browser.runtime.onInstalled.addListener(() => {
  try {
    createMenus();
  } catch {
    // duplicate menu items on update — ignore
  }
});

browser.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === "fetchster-link" && info.linkUrl) {
    const result = await nativeCall({
      url: info.linkUrl,
      userAgent: navigator.userAgent,
    });
    notify("Fetchster", result && result.ok ? "Added to Fetchster" : "Could not add to Fetchster");
    return;
  }

  if (info.menuItemId === "fetchster-page" && tab && tab.url) {
    const id = videoIdFromURL(tab.url);
    if (id) {
      const result = await nativeCall({
        type: "youtube",
        videoId: id,
        format: "b",
        browser: "safari",
      });
      notify("Fetchster", result && result.ok ? "Added to Fetchster" : "Could not add to Fetchster");
    } else {
      notify("Fetchster", "Not a supported page");
    }
  }
});

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message !== "object") return false;

  if (message.type === "ping") {
    nativeCall({ type: "ping" }).then(sendResponse);
    return true;
  }

  if (message.type === "capture" || message.type === "youtube") {
    nativeCall({ ...message, userAgent: navigator.userAgent }).then((response) => {
      sendResponse(response);
      if (response && response.ok) {
        notify("Fetchster", "Added to Fetchster");
      }
    });
    return true;
  }

  return false;
});
