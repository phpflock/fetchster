// Fetchster Safari — content script.
// 1) Intercepts clicks on file download links and hands them to Fetchster.
// 2) Optionally adds a "Download with Fetchster" button on video pages
//    (off by default; enable it in the extension popup).

(function () {
  const DOWNLOAD_EXT = /\.(zip|dmg|pkg|pdf|iso|tar|gz|bz2|xz|7z|rar|exe|msi|apk|png|jpg|jpeg|gif|webp|mp3|wav|flac|mov|avi|mkv|mp4|m4v|epub|docx?|xlsx?|pptx?|csv|json|txt)$/i;

  function isPlainLeftClick(event) {
    if (event.defaultPrevented || event.button !== 0) return false;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return false;
    return true;
  }

  function isFileDownloadLink(anchor) {
    if (!anchor || !anchor.href) return false;
    if (anchor.hasAttribute("download")) return true;
    try {
      const url = new URL(anchor.href, window.location.href);
      if (url.protocol === "magnet:") return false; // app handles magnets at OS level
      if (url.pathname.toLowerCase().endsWith(".torrent")) return false; // app handles torrents
      return DOWNLOAD_EXT.test(url.pathname);
    } catch {
      return false;
    }
  }

  document.addEventListener(
    "click",
    (event) => {
      const target = event.target;
      const anchor = target && target.closest ? target.closest("a[href]") : null;
      if (!anchor || !isPlainLeftClick(event) || !isFileDownloadLink(anchor)) return;

      event.preventDefault();
      event.stopPropagation();
      browser.runtime.sendMessage({
        type: "capture",
        url: anchor.href,
        referer: window.location.href,
        title: anchor.download || undefined,
      });
    },
    true
  );
})();

// Optional video-page button.
(function () {
  let enabled = false;

  function videoIdFromURL() {
    try {
      const url = new URL(window.location.href);
      const v = url.searchParams.get("v");
      if (v) return v;
      if (url.hostname === "youtu.be") {
        const id = url.pathname.slice(1);
        if (id) return id;
      }
    } catch {}
    return null;
  }

  function removeButton() {
    const existing = document.getElementById("fetchster-yt-btn");
    if (existing && existing.parentElement) existing.parentElement.removeChild(existing);
  }

  function maybeAddButton() {
    removeButton();
    if (!enabled) return;
    const id = videoIdFromURL();
    if (!id) return;

    const button = document.createElement("button");
    button.id = "fetchster-yt-btn";
    button.textContent = "Download with Fetchster";
    button.style.cssText =
      "margin:8px 0;padding:9px 16px;border:0;border-radius:18px;" +
      "background:#0a84ff;color:#fff;font:600 14px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;" +
      "cursor:pointer;";
    button.addEventListener("click", () => {
      browser.runtime.sendMessage({
        type: "youtube",
        videoId: id,
        format: "b",
        browser: "safari",
      });
    });

    const title = document.querySelector("#title h1");
    if (title && title.parentElement) {
      title.parentElement.insertBefore(button, title.nextSibling);
      return;
    }
    const anchor = document.querySelector("#above-the-fold") || document.body;
    if (anchor) anchor.prepend(button);
  }

  browser.storage.local.get({ youtube: false }).then((stored) => {
    enabled = !!stored.youtube;
    maybeAddButton();
  });
  browser.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.youtube) {
      enabled = !!changes.youtube.newValue;
      maybeAddButton();
    }
  });

  window.addEventListener("load", maybeAddButton);
  document.addEventListener("yt-navigate-finish", maybeAddButton);
  maybeAddButton();
})();
