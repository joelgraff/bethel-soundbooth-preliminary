// Cockpit widget: livestream start/stop + the four DP output preview tiles.
// A pinned, always-on page for DP-1 (see docs/dp1-desktop-cockpit-plan.md) —
// deliberately just this one card and the HDMI grid, not the full dashboard,
// so it can sit permanently in a narrow tiled column without navigation.
// Same confirm-token flow as the main dashboard's quick-action button
// (dashboard.js renderQuickActions) — this is a second, minimal view onto
// the same REST endpoints, not a separate authority path.

const RELAY_UNIT = "ffmpeg-srt-relay.service";

async function refreshRelayStatus() {
  const lamp = document.getElementById("relay-lamp");
  const label = document.getElementById("relay-label");
  const sub = document.getElementById("relay-sub");
  const btn = document.getElementById("relay-btn");
  let data;
  try {
    data = await api.services();
  } catch (err) {
    label.textContent = "Status unavailable";
    sub.textContent = err.message;
    return;
  }
  const svc = data.services.find((s) => s.unit === RELAY_UNIT);
  const isRunning = !!svc && svc.active_state === "active";
  lamp.className = isRunning ? "tally-lamp live" : "tally-lamp";
  label.textContent = isRunning ? "LIVE — on Subsplash" : "Off air";
  sub.textContent = isRunning ? "Streaming now" : "Not streaming";
  btn.textContent = isRunning ? "Stop Livestream" : "Start Livestream";
  btn.className = `btn ${isRunning ? "btn-warn" : "btn-primary"}`;
  btn.disabled = false;
  btn.onclick = () => handleRelayAction(isRunning ? "stop" : "start");
}

async function handleRelayAction(action, confirmToken) {
  const btn = document.getElementById("relay-btn");
  btn.disabled = true;
  try {
    const fn = action === "start" ? api.start : api.stop;
    const result = await fn(RELAY_UNIT, confirmToken);
    if (result && result.requires_confirmation) {
      showConfirmModal({
        title: action === "start" ? "Start Livestream?" : "Stop Livestream?",
        message: result.message,
        confirmLabel: action === "start" ? "Start" : "Stop",
        onConfirm: () => handleRelayAction(action, result.confirm_token),
      });
      return;
    }
    showToast(action === "start" ? "Livestream started" : "Livestream stopped");
  } catch (err) {
    showToast(`Failed: ${err.message}`);
  } finally {
    await refreshRelayStatus();
  }
}

(async function init() {
  await bootstrapLocalToken();
  await Promise.all([refreshRelayStatus(), loadHdmiGrid()]);
  setInterval(refreshRelayStatus, 4000);
})();
