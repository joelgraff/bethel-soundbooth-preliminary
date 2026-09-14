// Soundbooth Control Dashboard — main page logic.
// Everything here reads from the real API in dashboard/backend/app; nothing
// on this page is sample/fake data. Where a subsystem isn't built yet (the AI
// agent bridge) the UI says so instead of faking it.

const HDMI_OUTPUTS = [
  { display: "DP-4", name: "DP-4 · Back TVs", role: "Split that feeds the back-of-house TVs", program: true },
  { display: "LIVESTREAM", name: "Livestream", role: "Encode leg sent to the SRT relay (Subsplash)" },
  { display: "DP-2", name: "DP-2 · FreeShow Primary", role: "Front (sanctuary main screen)" },
  { display: "DP-3", name: "DP-3 · FreeShow Stage", role: "Stage confidence monitor" },
];

// Best-effort mapping from a health-check "section" (the exact strings
// soundbooth-health.sh's log_result calls use — verified against
// audio-routing/scripts/soundbooth-health.sh, not guessed) to a real
// quick-fix action. Left out entirely (no button) for anything hardware/
// network — restarting a service won't fix an unplugged cable or a
// powered-off camera. Two of these keys were silently dead until this
// review (never matched a real section name, so their buttons never
// rendered): "camera-management" should have been "camera-mgmt", and
// "displays" — meant for xrandr/monitor-connectivity checks, which are
// hardware-only (no monitor detected, connector down, XAUTHORITY unset) —
// was removed rather than renamed, since restarting ffmpeg-display.service
// genuinely can't fix any of those, matching the principle above.
const SECTION_QUICK_FIX = {
  "audio": { unit: "ensure-audio-routes.service", action: "restart" },
  "foh-graph": { unit: "ensure-audio-routes.service", action: "restart" },
  "camera-mgmt": { unit: "camera-management.service", action: "restart" },
  "video": { unit: "ffmpeg-display.service", action: "restart" },
};

let latestServicesResponse = null;
let latestUnitIndex = {}; // unit -> {display_name, group, ...status}

function tick() {
  document.getElementById("clock").textContent = new Date().toLocaleString(undefined, {
    weekday: "short", hour: "2-digit", minute: "2-digit",
  });
}
tick();
setInterval(tick, 30000);

document.getElementById("logout-btn").addEventListener("click", async () => {
  await api.logout();
  window.location.href = "/login.html";
});

// ---------- Health ----------

let healthLoadedAt = null;

async function loadHealth() {
  let data;
  try {
    data = await api.health();
  } catch (err) {
    renderHealthError(err);
    return;
  }
  healthLoadedAt = Date.now();
  renderHealth(data);
}

function renderHealth(data) {
  const banner = document.getElementById("health-banner");
  const headline = document.getElementById("health-headline");
  const sub = document.getElementById("health-sub");
  const iconEl = document.getElementById("health-icon");
  const issuesEl = document.getElementById("health-issues");

  banner.classList.remove("good", "warn", "fail");
  let cls = "good", text = "All Systems Normal", color = "var(--good)";
  if (data.fail > 0) { cls = "fail"; text = "Attention Needed"; color = "var(--fail)"; }
  else if (data.warn > 0) { cls = "warn"; text = "Running With Warnings"; color = "var(--warn)"; }
  banner.classList.add(cls);
  headline.textContent = text;
  iconEl.innerHTML = data.fail > 0 || data.warn > 0
    ? ICONS.warningTriangle(32, color)
    : ICONS.checkCircle(32, color);
  sub.textContent = `${data.pass} checks passed · ${data.warn} warning${data.warn === 1 ? "" : "s"} · ${data.fail} failure${data.fail === 1 ? "" : "s"} · updated ${timeAgo(healthLoadedAt)}`;

  issuesEl.classList.remove("stale");

  const issues = (data.checks || []).filter((c) => c.level === "WARN" || c.level === "FAIL");
  issuesEl.innerHTML = issues.map((issue) => {
    const iconColor = issue.level === "FAIL" ? "var(--fail)" : "var(--warn)";
    const fix = SECTION_QUICK_FIX[issue.section];
    return `
      <div class="health-issue" id="health-issue-${escapeHtml(issue.section)}">
        <div style="display:flex; align-items:center; gap:12px;">
          ${ICONS.warningTriangle(18, iconColor)}
          <div style="font-size:13.5px;"><span class="mono" style="color:var(--text-faint); font-size:11px;">${escapeHtml(issue.section)}</span> &nbsp;${escapeHtml(issue.message)}</div>
        </div>
        ${fix ? `<button class="btn btn-warn btn-sm">Quick Fix</button>` : ""}
      </div>`;
  }).join("");

  // Wire quick-fix buttons — zip against only the issues that got a
  // button (querySelectorAll only finds those), not the full issues list,
  // or the two would drift out of alignment as soon as one issue has no fix.
  const issuesWithFix = issues.filter((issue) => SECTION_QUICK_FIX[issue.section]);
  issuesEl.querySelectorAll("button.btn-warn").forEach((btn, i) => {
    const fix = SECTION_QUICK_FIX[issuesWithFix[i].section];
    btn.addEventListener("click", async () => {
      btn.disabled = true;
      try {
        await api.restart(fix.unit);
        showToast(`Restarted ${fix.unit}`);
        await Promise.all([loadHealth(), loadServices()]);
      } catch (err) {
        showToast(`Failed: ${err.message}`);
      } finally {
        btn.disabled = false;
      }
    });
  });

  renderTroubleshooting(issues);
}

function renderHealthError(err) {
  const banner = document.getElementById("health-banner");
  banner.classList.remove("good", "warn");
  banner.classList.add("fail");
  document.getElementById("health-headline").textContent = "Health check unavailable";
  document.getElementById("health-icon").innerHTML = ICONS.warningTriangle(32, "var(--fail)");
  document.getElementById("health-sub").textContent = err.message || "Could not reach the health check.";

  // The banner above is the only thing this function used to touch — the
  // detailed issue lists below kept showing whatever they last loaded with no
  // indication it might no longer be current, which is actively misleading
  // during exactly the moment (a backend hiccup) an operator needs to trust
  // this page. Mark them stale instead of leaving them looking live.
  [document.getElementById("health-issues"), document.getElementById("trbl-issues")].forEach((el) => {
    if (!el || !el.children.length || el.classList.contains("stale")) return;
    el.classList.add("stale");
    const notice = document.createElement("div");
    notice.className = "stale-notice";
    notice.textContent = "Health check unavailable — showing last known status.";
    el.prepend(notice);
  });
}

function renderTroubleshooting(issues) {
  const el = document.getElementById("trbl-issues");
  el.classList.remove("stale");
  if (issues.length === 0) {
    el.innerHTML = `<div style="font-size:12.5px; color:var(--text-muted);">Nothing needs attention.</div>`;
    return;
  }
  // A compact index, not a second full copy of "Attention Needed" above (same
  // full message + Quick Fix button already live there — repeating both here
  // was pure duplication). issue-sub is single-line/truncated by CSS; the full
  // message is still in the title tooltip, and a click jumps to and briefly
  // highlights the matching row up top rather than repeating it.
  el.innerHTML = issues.map((issue) => `
    <div class="issue-row ${issue.level === "FAIL" ? "fail" : "warn"}" data-jump-section="${escapeHtml(issue.section)}" title="${escapeHtml(issue.message)}">
      ${ICONS.warningTriangle(14, issue.level === "FAIL" ? "var(--fail)" : "var(--warn)")}
      <div class="issue-body">
        <div class="issue-title">${escapeHtml(issue.section)}</div>
        <div class="issue-sub">${escapeHtml(issue.message)}</div>
      </div>
    </div>`).join("");

  el.querySelectorAll("[data-jump-section]").forEach((row) => {
    row.addEventListener("click", () => {
      const target = document.getElementById(`health-issue-${row.dataset.jumpSection}`);
      if (!target) return;
      target.scrollIntoView({ behavior: "smooth", block: "center" });
      target.classList.add("flash-highlight");
      setTimeout(() => target.classList.remove("flash-highlight"), 1500);
    });
  });
}

// ---------- Services ----------

function stateOf(svc) {
  if (svc.active_state === "active") return { cls: "good", label: "Running" };
  if (svc.active_state === "activating") return { cls: "warn", label: "Starting" };
  if (svc.active_state === "failed" || svc.result === "exit-code") return { cls: "fail", label: "Failed" };
  return { cls: "off", label: "Stopped" };
}

async function loadServices() {
  let data;
  try {
    data = await api.services();
  } catch (err) {
    return;
  }
  latestServicesResponse = data;
  latestUnitIndex = {};
  data.services.forEach((s) => { latestUnitIndex[s.unit] = s; });
  renderServices(data);
  renderQuickActions(data);
  renderLogPicker(data);
}

function renderServices(data) {
  const listEl = document.getElementById("svc-list");
  const byUnit = latestUnitIndex;
  // Rebuilding via innerHTML resets scrollTop to 0 — this runs on an 8s poll,
  // so without saving/restoring it an operator scrolled down to check on a
  // service below the fold gets snapped back to the top before they can read it.
  const savedScrollTop = listEl.scrollTop;

  let html = "";
  let running = 0, total = 0, anyFail = false, anyOther = false;
  data.groups.forEach((group) => {
    html += `<div class="lbl svc-group-label">${escapeHtml(group.label)}</div>`;
    group.units.forEach((entry) => {
      const svc = byUnit[entry.unit] || {};
      const st = stateOf(svc);
      total++;
      if (st.cls === "good") running++;
      if (st.cls === "fail") anyFail = true;
      if (st.cls !== "good") anyOther = true;

      const actions = entry.actions || [];
      let actionButtons = "";
      if (actions.includes("restart")) {
        actionButtons += `<button class="icon-btn" data-action="restart" data-unit="${entry.unit}" title="Restart">${ICONS.restart()}</button>`;
      }
      if (actions.includes("start") || actions.includes("stop")) {
        const isRunning = st.cls === "good";
        const nextAction = isRunning ? "stop" : "start";
        const label = isRunning ? "Stop" : "Start";
        actionButtons += `<button class="btn ${isRunning ? "btn-ghost" : "btn-primary"} btn-sm" data-action="${nextAction}" data-unit="${entry.unit}">${label}</button>`;
      }

      html += `
        <div class="svc-row" data-row-unit="${entry.unit}">
          <div class="svc-dot ${st.cls}"></div>
          <div class="svc-name">
            <a href="/service.html?unit=${encodeURIComponent(entry.unit)}">${escapeHtml(entry.display_name)}</a>
            <span class="svc-unit mono">${escapeHtml(entry.unit.replace(".service", ""))}</span>
          </div>
          <div class="svc-state ${st.cls}">${st.label}</div>
          <div class="svc-actions">${actionButtons}</div>
        </div>`;
    });
  });
  listEl.innerHTML = html;
  listEl.scrollTop = savedScrollTop;

  const summaryEl = document.getElementById("svc-summary");
  summaryEl.textContent = `${running} of ${total} running`;
  summaryEl.className = "pill " + (anyFail ? "pill-fail" : anyOther ? "pill-warn" : "pill-good");

  listEl.querySelectorAll("button[data-action]").forEach((btn) => {
    btn.addEventListener("click", () => handleAction(btn.dataset.unit, btn.dataset.action));
  });
}

async function handleAction(unit, action, confirmToken) {
  const row = document.querySelector(`[data-row-unit="${CSS.escape(unit)}"]`);
  if (row) row.classList.add("is-loading");
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
        onConfirm: () => handleAction(unit, action, result.confirm_token),
      });
      return;
    }
    showToast(`${unit}: ${action} done`);
    await Promise.all([loadServices(), loadHealth()]);
  } catch (err) {
    showToast(`Failed: ${err.message}`);
  } finally {
    if (row) row.classList.remove("is-loading");
  }
}

function renderQuickActions(data) {
  const el = document.getElementById("quick-actions");
  el.innerHTML = data.quick_actions.map((qa) => {
    const svc = latestUnitIndex[qa.unit] || {};
    const isRelay = qa.id === "livestream_start";
    let action = qa.action, label = qa.label, caption = qa.caption, primary = false;
    if (isRelay) {
      const isRunning = svc.active_state === "active";
      action = isRunning ? "stop" : "start";
      label = isRunning ? "Stop Livestream" : "Start Livestream";
      caption = isRunning ? "Currently live" : "Currently off";
      primary = !isRunning;
    }
    const icon = qa.unit.includes("srt-relay") ? ICONS.broadcast()
      : qa.unit.includes("audio-routes") ? ICONS.speaker()
      : qa.unit.includes("display") ? ICONS.tv()
      : ICONS.camera();
    return `
      <button class="btn ${primary ? "btn-primary" : "btn-ghost"}" data-qa-unit="${qa.unit}" data-qa-action="${action}">
        ${icon}
        <span>
          <div class="qa-label">${escapeHtml(label)}</div>
          <div class="qa-caption">${escapeHtml(caption)}</div>
        </span>
      </button>`;
  }).join("");

  el.querySelectorAll("button[data-qa-unit]").forEach((btn) => {
    btn.addEventListener("click", () => handleAction(btn.dataset.qaUnit, btn.dataset.qaAction));
  });
}

// ---------- Service log picker ----------

function renderLogPicker(data) {
  const select = document.getElementById("log-unit-select");
  if (select.options.length > 0) return; // build once
  const opts = ['<option value="">Choose a service…</option>'];
  data.groups.forEach((group) => {
    group.units.forEach((entry) => {
      opts.push(`<option value="${entry.unit}">${escapeHtml(entry.display_name)} (${group.label})</option>`);
    });
  });
  select.innerHTML = opts.join("");
  select.addEventListener("change", async () => {
    const unit = select.value;
    const view = document.getElementById("log-view");
    if (!unit) { view.textContent = "Select a service above."; return; }
    view.textContent = "Loading…";
    try {
      const res = await api.logs(unit, 40);
      view.innerHTML = res.lines.length
        ? res.lines.map((l) => `<div>${escapeHtml(l)}</div>`).join("")
        : "<div>No recent log lines.</div>";
      view.scrollTop = view.scrollHeight;
    } catch (err) {
      view.textContent = `Could not load log: ${err.message}`;
    }
  });
}

// ---------- HDMI preview grid ----------
// All four tiles poll a real captured JPEG (see dashboard/README.md for the
// capture pipeline): DP-2/DP-3 via Mutter ScreenCast, DP-4/LIVESTREAM via
// dedicated ffmpeg-capture UDP tee legs (:5002 and :5001 respectively —
// each its own port so neither competes with ffplay's :5000 or the SRT
// relay's :5003 for an exclusive unicast reader). DP-1 (the booth's own
// operator screen) is deliberately not shown — lowest value to preview
// remotely, and it's what an operator standing at the booth already sees.

function renderHdmiGrid() {
  const grid = document.getElementById("hdmi-grid");
  grid.innerHTML = HDMI_OUTPUTS.map((o) => `
    <div class="hdmi-tile" id="hdmi-${o.display}">
      ${o.program ? '<div class="hdmi-badge">PROGRAM</div>' : ""}
      <div class="hdmi-dot off" id="hdmi-dot-${o.display}"></div>
      <img class="hdmi-img" id="hdmi-img-${o.display}" style="display:none; width:100%; height:100%; object-fit:cover;">
      <div class="hdmi-placeholder" id="hdmi-placeholder-${o.display}">${ICONS.monitor(36)}</div>
      <div class="hdmi-caption">
        <div class="name">${escapeHtml(o.name)}</div>
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

// ---------- A/V sync calibration ----------
// Rolled into the dashboard specifically so it can coordinate with the DP-4
// preview capture over the shared :5002 UDP tee instead of racing it — see
// dashboard/backend/app/calibrate.py.

document.getElementById("calibrate-btn").addEventListener("click", runCalibration);

async function runCalibration() {
  const btn = document.getElementById("calibrate-btn");
  const resultEl = document.getElementById("calibrate-result");
  btn.disabled = true;
  btn.textContent = "Running… (~12s, DP-4 preview will pause)";
  resultEl.style.display = "none";
  try {
    const data = await api.calibrate();
    const interp = data.interpret;
    let cls = "good", label = "In sync";
    if (interp.verdict === "no_markers") {
      cls = "warn";
      label = "No calibration pattern detected";
    } else if (!interp.in_sync) {
      cls = "warn";
      label = interp.verdict === "audio_late" ? "Audio is late" : "Audio is early";
    }
    resultEl.style.background = cls === "good" ? "var(--good-bg)" : "var(--warn-bg)";
    resultEl.style.border = `1px solid ${cls === "good" ? "var(--good-border)" : "var(--warn-border)"}`;
    const suggested = interp.suggested_delay_meaningful !== false
      ? ` · Suggested: ${interp.suggested_delay_sec}s`
      : "";
    resultEl.innerHTML = `
      <div style="font-weight:700; margin-bottom:4px;">${escapeHtml(label)}</div>
      <div>${escapeHtml(interp.note || "")}</div>
      <div style="margin-top:6px; color:var(--text-muted);">Current delay: ${interp.current_delay_sec}s${suggested}</div>
      <div style="margin-top:4px; font-size:11px; color:var(--text-faint);">Applying a new delay is a manual step (edit the config, restart the program encode) — not done automatically from here.</div>`;
    resultEl.style.display = "block";
  } catch (err) {
    resultEl.style.background = "var(--fail-bg)";
    resultEl.style.border = "1px solid var(--fail-border)";
    resultEl.textContent = `Calibration failed: ${err.message}`;
    resultEl.style.display = "block";
  } finally {
    btn.disabled = false;
    btn.textContent = "Run A/V Sync Check";
  }
}

// ---------- AI agent chat (see dashboard/docs/agent-tools.md) ----------
//
// One shared session on the backend: every connected panel sees the same
// stream, so the UI just renders whatever events arrive rather than tracking
// its own turn. Confirm-gated actions (livestream start/stop) arrive as a
// `confirm_request`; the actual execution is this browser calling the same
// REST endpoint a button would — the model never holds the token.

let agentWs = null;
let agentConfigured = false;
let agentReconnectTimer = null;
let agentAssistantBubble = null;

function chatAppend(cls, text) {
  const log = document.getElementById("chat-log");
  const div = document.createElement("div");
  div.className = `chat-bubble ${cls}`;
  div.textContent = text;
  log.appendChild(div);
  log.scrollTop = log.scrollHeight;
  return div;
}

function setChatEnabled(on) {
  document.getElementById("chat-input").disabled = !on;
  document.getElementById("chat-send").disabled = !on;
}

function sendAgent(obj) {
  if (agentWs && agentWs.readyState === WebSocket.OPEN) agentWs.send(JSON.stringify(obj));
}

function submitChatInput() {
  const input = document.getElementById("chat-input");
  const text = input.value.trim();
  if (!text || !agentConfigured) return;
  sendAgent({ type: "user_message", text });
  input.value = "";
}

function handleAgentEvent(msg) {
  const dot = document.getElementById("chat-dot");
  const statusText = document.getElementById("chat-status-text");

  switch (msg.type) {
    case "ready":
      agentConfigured = !!msg.configured;
      dot.className = "dot online";
      statusText.textContent = agentConfigured
        ? (msg.busy ? "Working…" : `Ready · ${msg.model || "Claude"}`)
        : "No API key";
      setChatEnabled(agentConfigured && !msg.busy);
      break;
    case "user_echo":
      agentAssistantBubble = null;
      chatAppend("mine", msg.text);
      break;
    case "turn_start":
      agentAssistantBubble = null;
      setChatEnabled(false);
      statusText.textContent = "Working…";
      break;
    case "token":
      if (!agentAssistantBubble) agentAssistantBubble = chatAppend("", "");
      agentAssistantBubble.textContent += msg.text;
      document.getElementById("chat-log").scrollTop = 1e9;
      break;
    case "tool_call":
      chatAppend("system", `· ${msg.summary}`);
      break;
    case "tool_done":
      if (!msg.ok) chatAppend("system", `· ${msg.summary}`);
      break;
    case "confirm_request":
      showConfirmModal({
        title: msg.action === "stop" ? "Stop the livestream?" : "Start the livestream?",
        message: msg.message,
        confirmLabel: msg.action === "stop" ? "Stop broadcast" : "Go live",
        onConfirm: async () => {
          try {
            const fn = msg.action === "stop" ? api.stop : api.start;
            await fn(msg.unit, msg.token);
            showToast(msg.action === "stop" ? "Livestream stopped" : "Livestream started");
            sendAgent({ type: "confirm_result", unit: msg.unit, action: msg.action, ok: true, detail: "done" });
          } catch (err) {
            showToast(err.message || "Action failed");
            sendAgent({ type: "confirm_result", unit: msg.unit, action: msg.action, ok: false, detail: err.message || "failed" });
          }
        },
        onCancel: () => {
          sendAgent({ type: "confirm_result", unit: msg.unit, action: "confirm-cancelled", ok: false, detail: "" });
        },
      });
      break;
    case "turn_done":
      if (agentAssistantBubble && !agentAssistantBubble.textContent) {
        agentAssistantBubble.remove();
      }
      agentAssistantBubble = null;
      setChatEnabled(agentConfigured);
      statusText.textContent = agentConfigured ? "Ready" : "No API key";
      break;
    case "busy":
    case "error":
    case "system":
      chatAppend("system", msg.text);
      break;
  }
}

function connectAgentChat() {
  const proto = window.location.protocol === "https:" ? "wss" : "ws";
  const dot = document.getElementById("chat-dot");
  const statusText = document.getElementById("chat-status-text");
  document.getElementById("chat-avatar").innerHTML = ICONS.bot();
  document.getElementById("chat-send").innerHTML = ICONS.send();

  agentWs = new WebSocket(`${proto}://${window.location.host}/ws/agent`);

  agentWs.addEventListener("open", () => {
    clearTimeout(agentReconnectTimer);
    dot.className = "dot online";
    statusText.textContent = "Connecting…";
  });
  agentWs.addEventListener("message", (evt) => {
    let msg;
    try { msg = JSON.parse(evt.data); } catch (_) { return; }
    handleAgentEvent(msg);
  });
  agentWs.addEventListener("close", () => {
    dot.className = "dot offline";
    statusText.textContent = "Reconnecting…";
    setChatEnabled(false);
    agentReconnectTimer = setTimeout(connectAgentChat, 3000);
  });

  // Wire the input once.
  const input = document.getElementById("chat-input");
  if (!input.dataset.wired) {
    input.dataset.wired = "1";
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submitChatInput(); }
    });
    document.getElementById("chat-send").addEventListener("click", submitChatInput);
  }
}

// ---------- board recording ----------
// Raw ALSA capture (hw:3,0, 64ch) under the hood — PipeWire's own capture
// path for this device silently reads all-zero on every channel even with
// real signal present (root-caused 2026-09-04). See
// audio-routing/scripts/record-board.sh and
// dashboard/backend/app/recording.py for the full story. USB Sends 1-32
// map 1:1 to the board's own channel numbering, confirmed by the operator.

const REC_CHANNEL_COUNT = 32;
let recSelectedChannels = new Set();
let recIsRecording = false;

function renderRecChannelGrid() {
  const grid = document.getElementById("rec-channel-grid");
  grid.innerHTML = "";
  for (let ch = 1; ch <= REC_CHANNEL_COUNT; ch++) {
    const btn = document.createElement("div");
    btn.className = "rec-chan-btn";
    btn.textContent = ch;
    btn.dataset.channel = ch;
    btn.addEventListener("click", () => {
      if (recIsRecording) return;
      if (recSelectedChannels.has(ch)) recSelectedChannels.delete(ch);
      else recSelectedChannels.add(ch);
      btn.classList.toggle("active", recSelectedChannels.has(ch));
    });
    grid.appendChild(btn);
  }
}

function formatBytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function formatElapsed(sec) {
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${String(s).padStart(2, "0")}`;
}

async function refreshRecStatus() {
  let status;
  try {
    status = await api.recordingStatus();
  } catch (_) {
    return;
  }
  recIsRecording = !!status.recording;
  const pill = document.getElementById("rec-status-pill");
  const startBtn = document.getElementById("rec-start-btn");
  const stopBtn = document.getElementById("rec-stop-btn");
  const info = document.getElementById("rec-active-info");
  const nameInput = document.getElementById("rec-name");
  const splitInput = document.getElementById("rec-split");

  if (recIsRecording) {
    pill.className = "pill pill-warn";
    pill.textContent = "Recording";
    startBtn.style.display = "none";
    stopBtn.style.display = "";
    nameInput.disabled = true;
    splitInput.disabled = true;
    info.style.display = "";
    info.textContent = `${status.filenames.join(", ")} — ch ${status.channels.join(",")} — ${formatElapsed(status.elapsed_sec)}`;
    document.querySelectorAll(".rec-chan-btn").forEach((b) => {
      b.classList.toggle("active", status.channels.includes(Number(b.dataset.channel)));
    });
  } else {
    pill.className = "pill pill-neutral";
    pill.textContent = "Idle";
    startBtn.style.display = "";
    stopBtn.style.display = "none";
    nameInput.disabled = false;
    splitInput.disabled = false;
    info.style.display = "none";
  }
}

async function refreshRecList() {
  let data;
  try {
    data = await api.recordingList();
  } catch (_) {
    return;
  }
  const list = document.getElementById("rec-list");
  if (!data.recordings.length) {
    list.innerHTML = `<div class="mono" style="font-size:12px; color:var(--text-faint);">No recordings yet.</div>`;
    return;
  }
  list.innerHTML = data.recordings.map((r) => `
    <div class="rec-item">
      <div>
        <div class="rec-item-name">${escapeHtml(r.filename)}</div>
        <div class="rec-item-meta">${formatBytes(r.size_bytes)} · ${timeAgo(r.mtime * 1000)}</div>
      </div>
      <a class="btn btn-ghost btn-sm" href="/api/recording/download/${encodeURIComponent(r.filename)}" download>Download</a>
    </div>`).join("");
}

async function startRecording() {
  const channels = Array.from(recSelectedChannels).sort((a, b) => a - b);
  if (!channels.length) {
    showToast("Select at least one channel first");
    return;
  }
  const name = document.getElementById("rec-name").value.trim();
  const split = document.getElementById("rec-split").checked;
  try {
    await api.recordingStart(channels, name, split);
    showToast("Recording started");
  } catch (err) {
    showToast(err.message || "Failed to start recording");
    return;
  }
  await refreshRecStatus();
}

async function stopRecording() {
  try {
    await api.recordingStop();
    showToast("Recording saved");
  } catch (err) {
    showToast(err.message || "Failed to stop recording");
  }
  await refreshRecStatus();
  await refreshRecList();
}

async function initRecording() {
  renderRecChannelGrid();
  document.getElementById("rec-start-btn").addEventListener("click", startRecording);
  document.getElementById("rec-stop-btn").addEventListener("click", stopRecording);
  await Promise.all([refreshRecStatus(), refreshRecList()]);
  setInterval(refreshRecStatus, 2500);
  setInterval(refreshRecList, 15000);
}

// ---------- livestream schedule ----------
// ffmpeg-srt-relay.service is deliberately NOT started at boot, so
// livestream-autostart.timer is the only automatic start path — a disarmed timer
// means the Sunday stream silently never starts, which is why it's surfaced here
// and not left CLI-only. See SYSTEM-STATE.md and
// dashboard/backend/app/livestream_schedule.py.

const SCHED_DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
let schedSelectedDays = new Set();
let schedArmed = false;

// systemd normalizes a spec to e.g. "Sun *-*-* 09:23:00" / "Wed,Sun *-*-* 18:30:00",
// or "*-*-* 09:23:00" for daily. Return {days,time} only for that simple weekly
// shape; null for anything richer (multiple times, date components, non-zero
// seconds) so the UI shows it read-only instead of silently rewriting it.
function parseSimpleSpec(spec) {
  const m = /^(?:([A-Za-z]{3}(?:,[A-Za-z]{3})*)\s+)?\*-\*-\*\s+(\d{2}):(\d{2}):(\d{2})$/.exec(
    (spec || "").trim()
  );
  if (!m) return null;
  if (m[4] !== "00") return null;
  const days = m[1] ? m[1].split(",") : SCHED_DAYS.slice();
  if (!days.every((d) => SCHED_DAYS.includes(d))) return null;
  return { days, time: `${m[2]}:${m[3]}` };
}

function buildSpec(days, time) {
  // A bare time is systemd's "every day", which is tidier than listing all seven.
  if (days.length === 7) return time;
  const ordered = SCHED_DAYS.filter((d) => days.includes(d));
  return `${ordered.join(",")} ${time}`;
}

function renderSchedDays() {
  const row = document.getElementById("sched-days");
  row.innerHTML = "";
  SCHED_DAYS.forEach((d) => {
    const btn = document.createElement("div");
    btn.className = "sched-day-btn";
    btn.textContent = d;
    btn.dataset.day = d;
    btn.classList.toggle("active", schedSelectedDays.has(d));
    btn.addEventListener("click", () => {
      if (schedSelectedDays.has(d)) schedSelectedDays.delete(d);
      else schedSelectedDays.add(d);
      btn.classList.toggle("active", schedSelectedDays.has(d));
    });
    row.appendChild(btn);
  });
}

async function refreshSchedule() {
  let s;
  try {
    s = await api.scheduleGet();
  } catch (_) {
    return;
  }

  const pill = document.getElementById("sched-pill");
  const next = document.getElementById("sched-next");
  const warn = document.getElementById("sched-warn");
  const editor = document.getElementById("sched-editor");
  const advanced = document.getElementById("sched-advanced");

  schedArmed = !!s.armed;

  if (!s.installed) {
    pill.textContent = "not installed";
    pill.className = "pill pill-neutral";
    next.textContent = "livestream-autostart.timer is not installed on this machine.";
    editor.style.display = "none";
    advanced.style.display = "none";
    warn.style.display = "none";
    return;
  }

  pill.textContent = s.armed ? "armed" : "disarmed";
  pill.className = `pill ${s.armed ? "pill-good" : "pill-warn"}`;

  if (s.armed && s.next_run) next.textContent = `Next start: ${s.next_run}`;
  else if (!s.armed) next.textContent = "Auto-start is off — the stream will only start manually.";
  else next.textContent = "Armed, but no next run reported.";
  if (s.stream_active) next.textContent += "  ·  streaming now";

  // The regression this arrangement removed: a boot-enabled relay streams on
  // every boot, including midweek maintenance.
  if (s.relay_boot_enabled) {
    warn.style.display = "";
    warn.textContent =
      "ffmpeg-srt-relay.service is set to start at boot, so every boot will go live. " +
      "Expected state is 'static' — fix with: systemctl --user disable ffmpeg-srt-relay.service";
  } else {
    warn.style.display = "none";
  }

  const simple = s.schedule.length === 1 ? parseSimpleSpec(s.schedule[0]) : null;
  const armLabel = s.armed ? "Disarm" : "Arm";

  if (simple) {
    editor.style.display = "";
    advanced.style.display = "none";
    // Don't stomp the operator's in-progress edits on a poll tick.
    if (document.activeElement !== document.getElementById("sched-time")) {
      document.getElementById("sched-time").value = simple.time;
      schedSelectedDays = new Set(simple.days);
      renderSchedDays();
    }
    document.getElementById("sched-arm-btn").textContent = armLabel;
  } else {
    editor.style.display = "none";
    advanced.style.display = "";
    document.getElementById("sched-advanced-spec").textContent =
      s.schedule_text || "(none set)";
    document.getElementById("sched-arm-btn-adv").textContent = armLabel;
  }
}

async function saveSchedule() {
  const time = document.getElementById("sched-time").value;
  if (!time) {
    showToast("Pick a time first");
    return;
  }
  if (schedSelectedDays.size === 0) {
    showToast("Pick at least one day");
    return;
  }
  const spec = buildSpec([...schedSelectedDays], time);
  try {
    await api.scheduleSet(spec);
    showToast(`Schedule set: ${spec}`);
  } catch (err) {
    showToast(err.message || "Could not set schedule");
  }
  await refreshSchedule();
}

async function toggleSchedArmed() {
  const wantArmed = !schedArmed;
  const apply = async () => {
    try {
      await api.scheduleArm(wantArmed);
      showToast(wantArmed ? "Auto-start armed" : "Auto-start disarmed");
    } catch (err) {
      showToast(err.message || "Could not change the schedule");
    }
    await refreshSchedule();
  };
  // Disarming is the quiet failure mode — nothing breaks now, the stream just
  // doesn't start on Sunday — so confirm that direction only.
  if (!wantArmed) {
    showConfirmModal({
      title: "Turn off scheduled start?",
      message:
        "The livestream will no longer start on its own. Someone will have to start it " +
        "by hand, from here or with start-live-stream.sh.",
      confirmLabel: "Turn off",
      onConfirm: apply,
    });
    return;
  }
  await apply();
}

async function initSchedule() {
  renderSchedDays();
  document.getElementById("sched-save-btn").addEventListener("click", saveSchedule);
  document.getElementById("sched-arm-btn").addEventListener("click", toggleSchedArmed);
  document.getElementById("sched-arm-btn-adv").addEventListener("click", toggleSchedArmed);
  document.getElementById("sched-simplify-btn").addEventListener("click", () => {
    schedSelectedDays = new Set(["Sun"]);
    document.getElementById("sched-time").value = "09:23";
    renderSchedDays();
    document.getElementById("sched-advanced").style.display = "none";
    document.getElementById("sched-editor").style.display = "";
    showToast("Pick a day and time, then Save Schedule");
  });
  await refreshSchedule();
  setInterval(refreshSchedule, 10000);
}

// ---------- init ----------

(async function init() {
  await bootstrapLocalToken();
  await Promise.all([loadHealth(), loadServices(), loadHdmiGrid(), initRecording(), initSchedule()]);
  connectAgentChat();
  setInterval(() => { loadHealth(); loadServices(); }, 8000);
})();
