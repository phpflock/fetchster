async function init() {
  const stored = await browser.storage.local.get({ capture: true, youtube: false });
  document.getElementById("capture").checked = stored.capture !== false;
  document.getElementById("youtube").checked = !!stored.youtube;

  const status = document.getElementById("status");
  try {
    const response = await browser.runtime.sendMessage({ type: "ping" });
    if (response && response.ok) {
      status.textContent = "Fetchster: connected ✓";
      status.className = "ok";
    } else {
      status.textContent = "Fetchster: not ready";
      status.className = "bad";
    }
  } catch {
    status.textContent = "Fetchster: not running";
    status.className = "bad";
  }
}

document.getElementById("capture").addEventListener("change", (event) => {
  browser.storage.local.set({ capture: event.target.checked });
});

document.getElementById("youtube").addEventListener("change", (event) => {
  browser.storage.local.set({ youtube: event.target.checked });
});

init();
