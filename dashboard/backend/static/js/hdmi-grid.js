// Shared HDMI preview grid — used by the main dashboard (index.html) and by
// any cockpit widget that also needs a glance at the four outputs (see
// widget-livestream.js). Split out of dashboard.js so a widget doesn't have
// to pull in the whole dashboard page's logic just for this piece.
//
// All four tiles poll a real captured JPEG (see dashboard/README.md for the
// capture pipeline): DP-2/DP-3 via Mutter ScreenCast, DP-4/LIVESTREAM via
// dedicated ffmpeg-capture UDP tee legs (:5002 and :5001 respectively —
// each its own port so neither competes with ffplay's :5000 or the SRT
// relay's :5003 for an exclusive unicast reader). DP-1 (the booth's own
// operator screen) is deliberately not shown — lowest value to preview
// remotely, and it's what an operator standing at the booth already sees.

const HDMI_OUTPUTS = [
  { display: "DP-4", name: "Back TVs", role: "Split that feeds the back-of-house TVs", program: true },
  { display: "LIVESTREAM", name: "SRT relay", role: "Encode leg sent to the SRT relay (Subsplash)" },
  { display: "DP-2", name: "FreeShow Primary", role: "Front (sanctuary main screen)" },
  { display: "DP-3", name: "FreeShow Stage", role: "Stage confidence monitor" },
];

function renderHdmiGrid() {
  const grid = document.getElementById("hdmi-grid");
  grid.innerHTML = HDMI_OUTPUTS.map((o) => `
    <div class="hdmi-tile" id="hdmi-${o.display}">
      ${o.program ? '<div class="hdmi-badge">PROGRAM</div>' : ""}
      <div class="hdmi-dot off" id="hdmi-dot-${o.display}"></div>
      <img class="hdmi-img" id="hdmi-img-${o.display}" style="display:none; width:100%; height:100%; object-fit:cover;">
      <div class="hdmi-placeholder" id="hdmi-placeholder-${o.display}">${ICONS.monitor(36)}</div>
      <div class="hdmi-caption">
        <div class="name"><span class="mono" style="color:var(--text-faint); margin-right:6px;">${escapeHtml(o.display)}</span>${escapeHtml(o.name)}</div>
        <div class="role" id="hdmi-role-${o.display}">${escapeHtml(o.role)}</div>
      </div>
    </div>`).join("");
}

async function refreshHdmiTile(o) {
  const img = document.getElementById(`hdmi-img-${o.display}`);
  const placeholder = document.getElementById(`hdmi-placeholder-${o.display}`);
  const roleEl = document.getElementById(`hdmi-role-${o.display}`);
  const dot = document.getElementById(`hdmi-dot-${o.display}`);
  let status;
  try {
    status = await api.outputStatus(o.display);
  } catch (_) {
    return;
  }
  if (status.available) {
    img.src = `/api/outputs/${o.display}/frame.jpg?t=${Date.now()}`;
    img.style.display = "block";
    placeholder.style.display = "none";
    roleEl.textContent = o.role;
    dot.className = "hdmi-dot good";
  } else {
    img.style.display = "none";
    placeholder.style.display = "flex";
    roleEl.textContent = `${o.role} — ${status.reason || "not available"}`;
    dot.className = "hdmi-dot off";
  }
}

async function loadHdmiGrid() {
  renderHdmiGrid();
  await Promise.all(HDMI_OUTPUTS.map(refreshHdmiTile));
  setInterval(() => HDMI_OUTPUTS.forEach(refreshHdmiTile), 2500);
}
