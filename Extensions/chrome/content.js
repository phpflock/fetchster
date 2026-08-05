// Intercepts clicks on deterministic download links (magnet:, .torrent, and
// links with a download attribute) so the browser downloader never starts.
// Arbitrary file links can't be detected before the download begins, so those
// go through background.js (onCreated -> app -> cancel + erase).
(function () {
  let enabled = true;
  chrome.storage.local.get({ capture: true }, (stored) => {
    enabled = stored.capture !== false;
  });
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.capture) {
      enabled = changes.capture.newValue !== false;
    }
  });

  function isPlainLeftClick(event) {
    if (event.defaultPrevented || event.button !== 0) return false;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return false;
    return true;
  }

  function isDownloadLink(anchor) {
    const href = anchor.href || "";
    if (href.toLowerCase().startsWith("magnet:")) return true;
    if (anchor.hasAttribute("download")) return true;
    try {
      const url = new URL(href);
      if (url.pathname.toLowerCase().endsWith(".torrent")) return true;
    } catch {
      // ignore malformed URLs
    }
    return false;
  }

  document.addEventListener(
    "click",
    (event) => {
      if (!enabled) return;
      const target = event.target;
      const anchor = target && target.closest ? target.closest("a[href]") : null;
      if (!anchor || !isPlainLeftClick(event) || !isDownloadLink(anchor)) return;

      event.preventDefault();
      event.stopPropagation();
      chrome.runtime.sendMessage(
        {
          type: "idl-capture",
          url: anchor.href,
          referer: window.location.href,
          title: anchor.download || undefined,
        },
        () => {
          void chrome.runtime.lastError; // the frame may be gone by the time we respond
        }
      );
    },
    true // capture phase, so pages can't cancel our interception first
  );
})();

// ===== Browser detection =====
// yt-dlp reads cookies with --cookies-from-browser <name>; Brave exposes a
// unique navigator.brave API, so we can tell it apart from Chrome.
(function () {
  function browserName() {
    try {
      if (window.navigator.brave && typeof window.navigator.brave.isBrave === "function") {
        return "brave";
      }
    } catch {
      // not Brave
    }
    const ua = navigator.userAgent || "";
    if (/Edg\//.test(ua)) return "edge";
    if (/OPR\/|Opera/.test(ua)) return "opera";
    if (/Firefox\//.test(ua)) return "firefox";
    if (/Chrome\//.test(ua)) return "chrome";
    return "chrome";
  }
  chrome.runtime.sendMessage({ type: "idl-browser", name: browserName() }, () => {
    void chrome.runtime.lastError;
  });
})();

// ===== Video detection =====
// Reports <video> elements with a direct src/currentSrc so the app can offer
// them as downloadable streams (the webRequest listener in background.js
// covers streams actually fetched over the network).
(function () {
  function reportVideo(src) {
    if (!src) return;
    if (src.startsWith("blob:") || src.startsWith("data:")) return;
    chrome.runtime.sendMessage(
      { type: "idl-media-element", url: src },
      () => {
        void chrome.runtime.lastError; // frame may be gone
      }
    );
  }

  document.addEventListener(
    "loadedmetadata",
    (event) => {
      const video = event.target;
      if (!(video instanceof HTMLVideoElement)) return;
      reportVideo(video.currentSrc || video.src);
    },
    true
  );

  // Videos already loaded before this script attached.
  for (const video of document.querySelectorAll("video")) {
    if (video.readyState >= 1) {
      reportVideo(video.currentSrc || video.src);
    }
  }

  // Catch-up for media the extension's service worker missed while it was
  // cold-starting (e.g. fetch()'d manifests at page load): the page's own
  // resource timing list knows about them.
  function reportPerformanceMedia() {
    try {
      const entries = performance.getEntriesByType("resource");
      for (const entry of entries) {
        const name = entry.name;
        if (/\.(m3u8|mpd|mp4|webm|mkv|mov|m4v|flv|wmv|ogv|ts)(\?|#|$)/i.test(name)) {
          reportVideo(name);
        }
      }
    } catch {
      // performance API unavailable — webRequest detection still applies
    }
  }
  window.addEventListener("load", () => setTimeout(reportPerformanceMedia, 800));
  setTimeout(reportPerformanceMedia, 3000);
})();

// ===== Manifest body relay =====
// main-hook.js (MAIN world) captures manifest bodies and posts them here;
// this isolated-world listener forwards them to the background service
// worker.
(function () {
  window.addEventListener("message", (event) => {
    const data = event.data;
    if (!data || data.source !== "idl-downloader" || data.type !== "manifest") return;
    chrome.runtime.sendMessage(
      {
        type: "idl-media-manifest",
        url: data.url,
        contentType: data.contentType,
        body: data.body,
      },
      () => {
        void chrome.runtime.lastError;
      }
    );
  });
})();
