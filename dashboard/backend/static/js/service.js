// Service detail page. Only renders data the API actually provides — no
// fabricated uptime/CPU/memory numbers; the backend doesn't track those yet.

const params = new URLSearchParams(window.location.search);
const unit = params.get("unit");

document.getElementById("back-link").innerHTML = `${ICONS.chevronLeft()} Back to Dashboard`;

function stateOf(svc) {
  if (svc.active_state === "active") return { cls: "good", label: "Running" };
  if (svc.active_state === "activating") return { cls: "warn", label: "Starting" };
  if (svc.active_state === "failed" || svc.result === "exit-code") return { cls: "fail", label: "Failed" };
  return { cls: "neutral", label: "Stopped" };
}

let manifestEntry = null;
let groupLabel = "";

async function loadService() {
  if (!unit) {
    document.getElementById("svc-title").textContent = "No service specified";
    return;
  }
  let data;
  try {
    data = await api.services();
  } catch (err) {
    document.getElementById("svc-title").textContent = "Could not load";
    return;
  }
  for (const group of data.groups) {
    const entry = group.units.find((u) => u.unit === unit);
    if (entry) { manifestEntry = entry; groupLabel = group.label; break; }
  }
  if (!manifestEntry) {
    document.getElementById("svc-title").textContent = `Unknown service: ${unit}`;
    return;
  }
  const svc = data.services.find((s) => s.unit === unit) || {};
  renderHeader(svc);
  renderControls(svc);
  renderMetrics(svc);
}

function renderHeader(svc) {
  document.title = `${manifestEntry.display_name} · Soundbooth Control`;
  document.getElementById("svc-icon").innerHTML = ICONS.broadcast(24);
  document.getElementById("svc-title").textContent = manifestEntry.display_name;
  document.getElementById("svc-unit-name").textContent = unit;
  document.getElementById("svc-log-title").textContent = `· ${unit}`;

  const st = stateOf(svc);
  const pill = document.getElementById("svc-status-pill");
  pill.className = "pill pill-" + st.cls;
  pill.textContent = st.label;
}

function renderControls(svc) {
  const el = document.getElementById("svc-controls");
  const actions = manifestEntry.actions || [];
  const st = stateOf(svc);
  const buttons = [];

  if (actions.includes("restart")) {
    buttons.push(`<button class="btn btn-ghost" data-action="restart">${ICONS.restart(15)} Restart</button>`);
  }
  if (actions.includes("start")) {
    const disabled = st.cls === "good" ? "disabled" : "";
    buttons.push(`<button class="btn btn-primary" data-action="start" ${disabled}>${ICONS.play(15)} Start</button>`);
  }
  if (actions.includes("stop")) {
    const disabled = st.cls !== "good" ? "disabled" : "";
    buttons.push(`<button class="btn btn-ghost" data-action="stop" ${disabled}>${ICONS.stop(15)} Stop</button>`);
  }
  el.innerHTML = buttons.join("");
  el.querySelectorAll("button[data-action]").forEach((btn) => {
    btn.addEventListener("click", () => handleAction(btn.dataset.action));
  });
}

async function handleAction(action, confirmToken) {
  try {
    let result;
    if (action === "restart") result = await api.restart(unit);
    else if (action === "start") result = await api.start(unit, confirmToken);
    else result = await api.stop(unit, confirmToken);

    if (result && result.requires_confirmation) {
      showConfirmModal({
        title: action === "start" ? "Start service?" : "Stop service?",
        message: result.message,
        confirmLabel: action === "start" ? "Start" : "Stop",
        onConfirm: () => handleAction(action, result.confirm_token),
      });
      return;
    }
    showToast(`${action} done`);
    await loadService();
  } catch (err) {
    showToast(`Failed: ${err.message}`);
  }
}

function renderMetrics(svc) {
  const el = document.getElementById("svc-metrics");
  const rows = [
    ["Group", groupLabel],
    ["Active State", svc.active_state || "unknown"],
    ["Sub State", svc.sub_state || "unknown"],
    ["Result", svc.result || "unknown"],
  ];
  el.innerHTML = rows.map(([label, value]) => `
    <div>
      <div class="lbl">${escapeHtml(label)}</div>
      <div style="font-size:14px; margin-top:4px;" class="mono">${escapeHtml(value)}</div>
    </div>`).join("");
}

async function loadLog() {
  const view = document.getElementById("svc-log");
  if (!unit) return;
  view.textContent = "Loading…";
  try {
    const res = await api.logs(unit, 80);
    view.innerHTML = res.lines.length
      ? res.lines.map((l) => `<div>${escapeHtml(l)}</div>`).join("")
      : "<div>No recent log lines.</div>";
    view.scrollTop = view.scrollHeight;
  } catch (err) {
    view.textContent = `Could not load log: ${err.message}`;
  }
}

document.getElementById("refresh-log-btn").addEventListener("click", loadLog);

(async function init() {
  await loadService();
  await loadLog();
})();
