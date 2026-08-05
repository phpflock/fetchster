// Runs in the PAGE's main world (manifest: "world": "MAIN"), so it can hook
// the page's own fetch/XMLHttpRequest. Captures short-lived manifests (e.g.
// YouTube UMP) at the moment players receive them and relays the body to the
// isolated-world content script via postMessage.
(function () {
  window.__idlHook = true;

  function looksLikeManifest(url, contentType) {
    if (!url || url.indexOf("blob:") === 0 || url.indexOf("data:") === 0) return false;
    var lower = String(url).toLowerCase();
    var ct = String(contentType || "").toLowerCase();
    return ct.indexOf("yt-ump") !== -1
      || ct.indexOf("dash+xml") !== -1
      || ct.indexOf("mpegurl") !== -1
      || /\.(mpd|m3u8)(\?|$)/i.test(lower);
  }

  function report(url, contentType, body) {
    try {
      window.postMessage({
        source: "idl-downloader",
        type: "manifest",
        url: String(url),
        contentType: String(contentType || ""),
        body: String(body)
      }, "*");
    } catch (e) {}
  }

  var origFetch = window.fetch;
  if (typeof origFetch === "function") {
    window.fetch = function () {
      var args = arguments;
      var reqUrl = typeof args[0] === "string" ? args[0] : (args[0] && args[0].url) || "";
      return origFetch.apply(this, args).then(function (response) {
        try {
          var ct = response.headers.get("content-type") || "";
          if (looksLikeManifest(response.url || reqUrl, ct)) {
            response.clone().text().then(function (body) {
              if (body && body.length > 50) report(response.url || reqUrl, ct, body);
            }).catch(function () {});
          }
        } catch (e) {}
        return response;
      });
    };
  }

  var XHR = XMLHttpRequest.prototype;
  var xopen = XHR.open;
  var xsend = XHR.send;
  XHR.open = function (method, url) {
    this._idlUrl = url;
    return xopen.apply(this, arguments);
  };
  XHR.send = function () {
    this.addEventListener("load", function () {
      try {
        var ct = this.getResponseHeader("content-type") || "";
        if (looksLikeManifest(this.responseURL || this._idlUrl, ct)) {
          var body = this.responseText;
          if (body && body.length > 50) report(this.responseURL || this._idlUrl, ct, body);
        }
      } catch (e) {}
    });
    return xsend.apply(this, arguments);
  };
})();
