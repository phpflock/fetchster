#!/usr/bin/env python3
"""Drives the isolated test Chrome via the DevTools Protocol: clicks the test
page's download links and reports what lands in the app and in
chrome://downloads."""

import json
import os
import sys
import time
import urllib.request

import websocket

CDP_PORT = int(os.environ.get("CDP_PORT", "9222"))
FOCUS = os.environ.get("FOCUS") == "1"
CLICK_ONLY = os.environ.get("CLICK_ONLY", "")
APP_STATE = os.path.expanduser(
    "~/Library/Application Support/Fetchster/downloads.json"
)


def list_tabs():
    with urllib.request.urlopen(f"http://127.0.0.1:{CDP_PORT}/json/list", timeout=5) as response:
        return json.load(response)


def find_ws(url_substr):
    for tab in list_tabs():
        if tab.get("type") == "page" and url_substr in tab.get("url", ""):
            return tab["webSocketDebuggerUrl"]
    return None


def app_titles():
    if not os.path.exists(APP_STATE):
        return []
    with open(APP_STATE) as f:
        items = json.load(f)
    return [(i["title"], i["status"]) for i in items]


class CDP:
    def __init__(self, url):
        self.ws = websocket.create_connection(url, timeout=20)
        self.mid = 0
        self.logs = []
        self.contexts = []

    def send(self, method, params=None):
        self.mid += 1
        mid = self.mid
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
        while True:
            message = json.loads(self.ws.recv())
            if message.get("id") == mid:
                return message.get("result", {})
            if message.get("method") == "Runtime.consoleAPICalled":
                args = message.get("params", {}).get("args", [])
                values = [a.get("value", "") if isinstance(a, dict) else str(a) for a in args]
                self.logs.append(" ".join(str(v) for v in values))
            if message.get("method") == "Runtime.executionContextCreated":
                self.contexts.append(message.get("params", {}).get("context", {}))

    def js(self, expression):
        result = self.send("Runtime.evaluate", {
            "expression": expression,
            "returnByValue": True,
        })
        inner = result.get("result")
        return inner.get("value") if isinstance(inner, dict) else None


def main():
    print("=== targets ===")
    for tab in list_tabs():
        print(" ", tab.get("type"), "|", tab.get("url", "")[:80])

    ws_url = find_ws("testpage.html")
    if not ws_url:
        print("ERROR: test page tab not found", file=sys.stderr)
        sys.exit(1)

    page = CDP(ws_url)
    page.send("Runtime.enable")
    time.sleep(1)
    for context in page.contexts:
        aux = context.get("auxData", {})
        if aux.get("isDefault", True):
            continue
        value = page.send("Runtime.evaluate", {
            "expression": "window.__idlContentActive",
            "contextId": context["id"],
            "returnByValue": True,
        }).get("result", {}).get("value")
        print("isolated world", context.get("name", "?"), "-> content script active:", value)

    sw_url = None
    for tab in list_tabs():
        if tab.get("type") == "service_worker" and "chrome-extension" in tab.get("url", ""):
            sw_url = tab["webSocketDebuggerUrl"]
    sw = CDP(sw_url) if sw_url else None
    if sw:
        sw.send("Runtime.enable")
    print("service worker connected:", sw_url)

    def read_event_log():
        for context in page.contexts:
            aux = context.get("auxData", {})
            if aux.get("isDefault", True):
                continue
            value = page.send("Runtime.evaluate", {
                "expression": "new Promise((res) => chrome.storage.local.get('eventLog', (v) => res(v.eventLog || [])))",
                "contextId": context["id"],
                "returnByValue": True,
                "awaitPromise": True,
            }).get("result", {}).get("value")
            if value is not None:
                return value
        return None

    def click_element(element_id):
        """Trusted mouse click (real user activation) at the element center."""
        result = page.js(
            f"""
            (() => {{
              const el = document.getElementById('{element_id}');
              if (!el) return null;
              const r = el.getBoundingClientRect();
              return {{x: r.x + r.width / 2, y: r.y + r.height / 2}};
            }})()
            """
        )
        if not result:
            print(f"  element #{element_id} not found")
            return False
        x, y = result["x"], result["y"]
        page.send("Input.dispatchMouseEvent", {
            "type": "mouseMoved", "x": x, "y": y,
        })
        page.send("Input.dispatchMouseEvent", {
            "type": "mousePressed", "x": x, "y": y,
            "button": "left", "clickCount": 1,
        })
        page.send("Input.dispatchMouseEvent", {
            "type": "mouseReleased", "x": x, "y": y,
            "button": "left", "clickCount": 1,
        })
        return True

    if CLICK_ONLY:
        click_element(CLICK_ONLY)
        print("clicked", CLICK_ONLY)
        page.ws.close()
        return

    if FOCUS:
        steps = [
            ("plain link (browser-managed)", "plain", 6),
            ("link with download attribute", "attr", 6),
        ]
    else:
        steps = [
            ("plain link (browser-managed)", "plain", 6),
            ("link with download attribute", "attr", 6),
            ("magnet link", "magnet", 5),
            ("torrent link", "torrent", 6),
        ]

    for name, element_id, wait in steps:
        before = app_titles()
        click_element(element_id)
        time.sleep(wait)
        for context in page.contexts:
            aux = context.get("auxData", {})
            if aux.get("isDefault", True):
                continue
            counters = page.send("Runtime.evaluate", {
                "expression": "[window.__idlClicks, window.__idlMatches, window.__idlPrevented]",
                "contextId": context["id"],
                "returnByValue": True,
            }).get("result", {}).get("value")
            if counters:
                print(f"  [counters after {name}] clicks={counters[0]} matches={counters[1]} prevented={counters[2]}")
                break
        after = app_titles()
        added = [t for t in after if t not in before]
        print(f"[{name}] app state delta: {added if added else 'NONE'}")
        log = read_event_log()
        print(f"  full event log: {json.dumps(log) if log else 'none'}")

    page.send("Page.navigate", {"url": "chrome://downloads"})
    time.sleep(3)
    pierce = """
    (() => {
      const out = [];
      function walk(root) {
        for (const el of root.querySelectorAll('*')) {
          if (el.shadowRoot) walk(el.shadowRoot);
          if (el.childElementCount === 0 && el.textContent && el.textContent.trim()) {
            out.push(el.textContent.trim());
          }
        }
      }
      walk(document.body || document.documentElement);
      return out.join('\\n');
    })()
    """
    text = page.js(pierce) or ""
    print("=== chrome://downloads page text ===")
    for line in text.splitlines():
        if any(k in line for k in ("No downloads", "cancelled", "failed", "payload", "attr-file", "sintel", "Complete")):
            print(" ", line)
    if not text.strip():
        print("  (empty)")
    print("=== final app state (all items) ===")
    for title, status in app_titles():
        print(" ", title, "|", status)
    print("=== extension service worker logs ===")
    print("\n".join(sw.logs) if sw and sw.logs else "  (none)")
    print("=== page logs ===")
    print("\n".join(page.logs) if page.logs else "  (none)")
    page.ws.close()


if __name__ == "__main__":
    main()
