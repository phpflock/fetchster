async function init() {
  const stored = await chrome.storage.local.get({ capture: true });
  document.getElementById("capture").checked = stored.capture !== false;

  const status = document.getElementById("status");
  try {
    const response = await chrome.runtime.sendMessage({ type: "idl-ping" });
    if (response && response.ok) {
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
