// AI agent chat client, shared by the main dashboard (index.html) and the
// cockpit chat widget (widget-chat.html). Needs api.js, icons.js, ui.js and the
// chat-* element ids (chat-log, chat-input, chat-send, chat-dot,
// chat-status-text, chat-avatar). Extracted from dashboard.js unchanged.

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
