// Shared fetch wrapper: same-origin, JSON in/out, redirects to the login
// page on 401 instead of every caller having to handle it.

async function apiFetch(path, options = {}) {
  const { redirectOn401 = true, ...rest } = options;
  const opts = {
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", ...(rest.headers || {}) },
    ...rest,
  };
  const res = await fetch(path, opts);
  if (res.status === 401) {
    if (redirectOn401) {
      window.location.href = "/login.html";
    }
    throw new Error("not authenticated");
  }
  let body = null;
  try {
    body = await res.json();
  } catch (_) {
    // no body
  }
  if (!res.ok) {
    const detail = (body && body.detail) || res.statusText;
    const err = new Error(detail);
    err.status = res.status;
    err.body = body;
    throw err;
  }
  return body;
}

const api = {
  session: () => apiFetch("/api/session"),
  login: (pin) => apiFetch("/api/login", { method: "POST", body: JSON.stringify({ pin }), redirectOn401: false }),
  logout: () => apiFetch("/api/logout", { method: "POST" }),
  health: () => apiFetch("/api/health"),
  services: () => apiFetch("/api/services"),
  logs: (unit, lines = 50) => apiFetch(`/api/services/${encodeURIComponent(unit)}/logs?lines=${lines}`),
  restart: (unit) => apiFetch(`/api/services/${encodeURIComponent(unit)}/restart`, { method: "POST" }),
  start: (unit, confirmToken) => apiFetch(`/api/services/${encodeURIComponent(unit)}/start`, {
    method: "POST", body: JSON.stringify({ confirm_token: confirmToken || null }),
  }),
  stop: (unit, confirmToken) => apiFetch(`/api/services/${encodeURIComponent(unit)}/stop`, {
    method: "POST", body: JSON.stringify({ confirm_token: confirmToken || null }),
  }),
  outputStatus: (display) => apiFetch(`/api/outputs/${encodeURIComponent(display)}`),
  calibrate: (duration) => apiFetch("/api/calibrate", { method: "POST", body: JSON.stringify({ duration: duration || null }) }),
  loginLocal: (token) => apiFetch("/api/login/local", {
    method: "POST", body: JSON.stringify({ token }), redirectOn401: false,
  }),
  recordingStatus: () => apiFetch("/api/recording/status"),
  recordingStart: (channels, name, split) => apiFetch("/api/recording/start", {
    method: "POST", body: JSON.stringify({ channels, name: name || null, split: !!split }),
  }),
  recordingStop: () => apiFetch("/api/recording/stop", { method: "POST" }),
  recordingList: () => apiFetch("/api/recording/list"),
};

// Booth-PC-only bootstrap: start-booth-dashboard-view.sh launches the local
// viewer with ?local_token=... in the URL. Exchange it for a real session
// once, then scrub it from the URL bar so it doesn't linger in history or
// get shared by accident. No-op (and harmless) for anyone else — a remote
// LAN visitor's URL never has this param, so they still hit the PIN screen.
async function bootstrapLocalToken() {
  const params = new URLSearchParams(window.location.search);
  const token = params.get("local_token");
  if (!token) return;
  try {
    await api.loginLocal(token);
  } catch (_) {
    // Invalid/stale token — fall through to the normal PIN flow.
  }
  params.delete("local_token");
  const qs = params.toString();
  history.replaceState(null, "", window.location.pathname + (qs ? `?${qs}` : ""));
}

function timeAgo(ts) {
  const secs = Math.max(0, Math.floor((Date.now() - ts) / 1000));
  if (secs < 5) return "just now";
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  return `${Math.floor(mins / 60)}h ago`;
}

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}
