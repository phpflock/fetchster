const SERVER = "http://127.0.0.1:8765";

async function init() {
  const stored = await chrome.storage.local.get({ capture: true });
  document.getElementById("capture").checked = stored.capture !== false;

  const status = document.getElementById("status");
  try {
    const response = await fetch(`${SERVER}/api/ping`, { cache: "no-store" });
    const json = await response.json();
    if (json.ok) {
      status.textContent = "Server: connected ✓";
      status.className = "ok";
    } else {
      status.textContent = "Server: not ready";
      status.className = "bad";
    }
  } catch {
    status.textContent = "Server: Fetchster is not running";
    status.className = "bad";
  }
}

document.getElementById("capture").addEventListener("change", (event) => {
  chrome.storage.local.set({ capture: event.target.checked });
});

init();
