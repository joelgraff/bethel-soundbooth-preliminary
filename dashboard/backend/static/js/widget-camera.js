// Cockpit widget: PTZ camera control — direction pad, zoom, home, and named
// presets. No video (see docs/dp1-desktop-cockpit-plan.md): it only drives the
// camera; the picture is on the program monitors.
//
// Movement is press-and-hold: while a button is held we re-send the drive
// command every HOLD_RESEND_MS, and send a stop on release. The backend also
// stops the camera by itself ~1.5 s after the last drive command (watchdog in
// app/ptz.py), so a lost mouse-up or a closed window cannot leave it panning.

const HOLD_RESEND_MS = 500;
const STATUS_POLL_MS = 3000;
const MAX_UI_SLOT = 89;

let ptzState = { reachable: false, power: "unknown", presets: [] };
let holdTimer = null;
let holdKind = null;
let holdBusy = false;

function speedValue() {
  return parseInt(document.getElementById("ptz-speed").value, 10) || 8;
}

function setControlsEnabled(enabled) {
  document.querySelectorAll("#ptz-pad .ptz-btn, .ptz-zoom .ptz-btn, .ptz-recall, .ptz-update")
    .forEach((b) => { b.disabled = !enabled; });
}

function renderStatus() {
  const lamp = document.getElementById("cam-lamp");
  const label = document.getElementById("cam-label");
  const sub = document.getElementById("cam-sub");
  const s = ptzState;
  if (!s.reachable) {
    lamp.className = "tally-lamp";
    label.textContent = "Camera unreachable";
    sub.textContent = s.error || "";
  } else if (s.power !== "on") {
    lamp.className = "tally-lamp";
    label.textContent = s.power === "standby" ? "Camera in standby" : `Camera power: ${s.power}`;
    sub.textContent = "Power the camera on to use these controls.";
  } else {
    lamp.className = "tally-lamp live";
    label.textContent = "Camera ready";
    sub.textContent = "";
  }
  setControlsEnabled(s.reachable && s.power === "on");
}

async function refreshStatus() {
  if (holdTimer) return; // don't compete with an active move
  try {
    ptzState = await api.ptzStatus();
  } catch (err) {
    ptzState = { reachable: false, power: "unknown", presets: ptzState.presets, error: err.message };
  }
  renderStatus();
  renderPresets();
}

// ---- press-and-hold driving ------------------------------------------

async function sendDrive(kind, dir) {
  if (holdBusy) return; // one request in flight; the next tick will catch up
  holdBusy = true;
  try {
    if (kind === "zoom") await api.ptzZoom(dir, 3);
    else await api.ptzMove(dir, speedValue());
  } catch (err) {
    stopHold(true);
    showToast(`Camera: ${err.message}`);
  } finally {
    holdBusy = false;
  }
}

function startHold(btn, kind, dir) {
  stopHold(false);
  holdKind = kind;
  btn.classList.add("held");
  sendDrive(kind, dir);
  holdTimer = setInterval(() => sendDrive(kind, dir), HOLD_RESEND_MS);
}

function stopHold(quiet) {
  if (holdTimer) {
    clearInterval(holdTimer);
    holdTimer = null;
    document.querySelectorAll(".ptz-btn.held").forEach((b) => b.classList.remove("held"));
    const stop = holdKind === "zoom" ? api.ptzZoom("stop", 0) : api.ptzMove("stop", 1);
    holdKind = null;
    stop.catch((err) => { if (!quiet) showToast(`Stop failed: ${err.message}`); });
  }
}

function wireHoldButton(btn, kind, dir) {
  btn.addEventListener("pointerdown", (e) => {
    if (btn.disabled) return;
    btn.setPointerCapture(e.pointerId);
    startHold(btn, kind, dir);
  });
  const release = () => stopHold(false);
  btn.addEventListener("pointerup", release);
  btn.addEventListener("pointercancel", release);
  btn.addEventListener("lostpointercapture", release);
}

// ---- presets -----------------------------------------------------------

function renderPresets() {
  const root = document.getElementById("ptz-presets");
  const presets = ptzState.presets || [];
  if (!presets.length) {
    root.innerHTML = '<div class="ptz-empty">No named presets yet. Aim the camera, name the view below, and save it.</div>';
  } else {
    root.innerHTML = presets.map((p) => `
      <div class="ptz-preset-row">
        <button class="btn btn-ghost ptz-recall" data-slot="${p.slot}">${escapeHtml(p.name)}<span class="ptz-slot">slot ${p.slot}</span></button>
        <button class="btn btn-ghost ptz-update" data-slot="${p.slot}" title="Store the camera's current view in this preset">Update</button>
        <button class="btn btn-ghost ptz-forget" data-slot="${p.slot}" title="Remove this name (camera slot is left as is)">✕</button>
      </div>`).join("");
    root.querySelectorAll(".ptz-recall").forEach((b) => { b.onclick = () => recallPreset(+b.dataset.slot); });
    root.querySelectorAll(".ptz-update").forEach((b) => { b.onclick = () => updatePreset(+b.dataset.slot); });
    root.querySelectorAll(".ptz-forget").forEach((b) => { b.onclick = () => forgetPreset(+b.dataset.slot); });
  }
  setControlsEnabled(ptzState.reachable && ptzState.power === "on");
  renderSlotOptions();
}

function renderSlotOptions() {
  const sel = document.getElementById("ptz-slot");
  const keep = sel.value;
  const named = new Map((ptzState.presets || []).map((p) => [p.slot, p.name]));
  let firstFree = null;
  let html = "";
  for (let s = 1; s <= MAX_UI_SLOT; s++) {
    if (!named.has(s) && firstFree === null) firstFree = s;
    html += `<option value="${s}">Slot ${s}${named.has(s) ? ` — ${escapeHtml(named.get(s))}` : ""}</option>`;
  }
  sel.innerHTML = html;
  sel.value = keep || String(firstFree || 1);
}

async function recallPreset(slot) {
  try {
    await api.ptzRecall(slot);
  } catch (err) {
    showToast(`Camera: ${err.message}`);
  }
}

function confirmSave({ name, slot, existingName }) {
  const replacing = existingName
    ? `This replaces the saved view for “${existingName}” (slot ${slot}).`
    : `Slot ${slot} may already hold a view saved from another app (CMP or the phone app); it will be replaced.`;
  return new Promise((resolve) => {
    showConfirmModal({
      title: `Save “${name}”?`,
      message: `Stores the camera's CURRENT view in slot ${slot}. ${replacing}`,
      confirmLabel: "Save view",
      onConfirm: () => resolve(true),
      onCancel: () => resolve(false),
    });
  });
}

async function saveView(name, slot, existingName) {
  if (!(await confirmSave({ name, slot, existingName }))) return;
  try {
    const res = await api.ptzSavePreset(name, slot, true, !!existingName);
    ptzState.presets = res.presets;
    renderPresets();
    showToast(`Saved “${name}”`);
  } catch (err) {
    showToast(`Not saved: ${err.message}`);
  }
}

function updatePreset(slot) {
  const existing = (ptzState.presets || []).find((p) => p.slot === slot);
  if (existing) saveView(existing.name, slot, existing.name);
}

function forgetPreset(slot) {
  const existing = (ptzState.presets || []).find((p) => p.slot === slot);
  if (!existing) return;
  showConfirmModal({
    title: `Remove “${existing.name}”?`,
    message: "Removes the name from this list only. The view stays stored in the camera's slot.",
    confirmLabel: "Remove",
    onConfirm: async () => {
      try {
        const res = await api.ptzDeletePreset(slot);
        ptzState.presets = res.presets;
        renderPresets();
      } catch (err) {
        showToast(`Failed: ${err.message}`);
      }
    },
  });
}

function onSaveNew() {
  const nameEl = document.getElementById("ptz-name");
  const slot = parseInt(document.getElementById("ptz-slot").value, 10);
  const name = nameEl.value.trim();
  if (!name) { showToast("Type a name for the preset first"); return; }
  const taken = (ptzState.presets || []).find((p) => p.slot === slot);
  saveView(name, slot, taken ? taken.name : null).then(() => { nameEl.value = ""; });
}

(async function init() {
  await bootstrapLocalToken();
  try {
    const saved = localStorage.getItem("ptz-speed");
    if (saved) document.getElementById("ptz-speed").value = saved;
  } catch (_) { /* storage unavailable: default speed */ }
  document.getElementById("ptz-speed").addEventListener("input", (e) => {
    try { localStorage.setItem("ptz-speed", e.target.value); } catch (_) { /* ignore */ }
  });
  document.querySelectorAll("#ptz-pad [data-dir]").forEach((b) => wireHoldButton(b, "move", b.dataset.dir));
  document.querySelectorAll(".ptz-zoom [data-zoom]").forEach((b) => wireHoldButton(b, "zoom", b.dataset.zoom));
  document.getElementById("ptz-home").onclick = async () => {
    try { await api.ptzHome(); } catch (err) { showToast(`Camera: ${err.message}`); }
  };
  document.getElementById("ptz-save").onclick = onSaveNew;
  // A hidden/blurred window must never keep driving the camera.
  window.addEventListener("blur", () => stopHold(true));
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) stopHold(true);
  });
  await refreshStatus();
  setInterval(refreshStatus, STATUS_POLL_MS);
})();
