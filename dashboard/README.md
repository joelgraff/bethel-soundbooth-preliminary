# Soundbooth Control Dashboard

Web dashboard for the church soundbooth: system health at a glance, start/
stop/restart controls for the systemd `--user` services, HDMI output
previews, an AI agent chat panel, and troubleshooting/logs — for a
non-technical Sunday volunteer operator, from the booth PC or the
soundbooth LAN subnet.

Design mockup (2 screens, static): see the conversation history / published
Claude Design canvas — `backend/static/` is the real, wired-up build of it.

## Status

Backend + frontend both work end-to-end against the real system (PIN login,
live health/services/logs, restart/start/stop with confirmation) and have
been smoke-tested locally. Not deployed as a service yet.

Working:
- PIN-gated session auth (`backend/static/login.html`)
- `GET /api/health` — wraps `soundbooth-health.sh --json` (already supports
  that flag, no changes needed there); rendered as the dashboard's health
  banner + a troubleshooting list of the actual failing/warning checks
- `GET /api/services` — status of every unit in `backend/app/units_manifest.json`,
  rendered as the grouped services list + quick-actions bar
- `POST /api/services/{unit}/restart` — allowlisted, unconfirmed (low-stakes)
- `POST /api/services/{unit}/start` / `stop` — allowlisted, confirm-token
  gated where the manifest marks it (currently just the livestream relay) —
  the frontend shows this as a real confirm dialog, not a fake one
- `GET /api/services/{unit}/logs` — service detail page + the dashboard's
  log picker both pull real `journalctl` output
- Service detail page (`service.html`) — only shows fields the API actually
  returns (active/sub state, result); does not fabricate uptime/CPU numbers
  the backend doesn't track

- `GET /api/outputs/{display}` / `GET /api/outputs/{display}/frame.jpg` —
  real low-fps JPEG previews for **DP-2 and DP-3** (via independent
  `org.gnome.Mutter.ScreenCast` `RecordMonitor` sessions — the same
  technique `booth-multiview.py` uses, but a separate process; see
  "HDMI preview capture" below) and **DP-4** (via the `ffmpeg-capture`
  UDP encode tee). **DP-1 is deliberately not captured** — see that
  section. Dashboard polls every ~2.5s; capture only writes a new frame
  when the source actually changed and no sooner than
  `HDMI_PREVIEW_MIN_INTERVAL_SEC` (default 2s) since the last write.
- `POST /api/calibrate` — runs `av-sync-calibrate.py capture-udp --json`,
  coordinating with the DP-4 preview capture so they don't fight over the
  shared `:5002` UDP tee (see "A/V sync calibration" below and
  `docs/agent-tools.md`). Read-only: reports the measured offset and a
  suggested delay, never writes it to the live config or restarts the
  program encode — applying a fix stays a manual step for now.

- AI agent chat panel — `/ws/agent` runs a real Claude session (one shared
  session for every connected panel) with the fixed toolset in
  `backend/app/agent.py` / `agent_tools.py`: health, service list/logs, HDMI
  output status, a few reference docs, `restart`, and *staging* (not
  completing) the livestream `start`/`stop`. Confirm-gated actions surface a
  Yes/No dialog and execute via the same REST endpoint a button uses — the
  model never holds the confirm token. Needs `ANTHROPIC_API_KEY` in
  `dashboard.conf` (see "Getting an API key" below); without it the panel
  loads but stays disabled with a notice.

## HDMI preview capture

Two independent, small capture processes (not started/enabled yet — see
"Running it locally"), writing to `/dev/shm/soundbooth-dashboard/*.jpg`:

- **`hdmi-preview-capture.py`** (`audio-routing/scripts/`, installed as
  `hdmi-preview.service`) — DP-2 (FreeShow Primary) + DP-3 (FreeShow Stage),
  via their own `RecordMonitor` ScreenCast sessions. Confirmed against the
  real booth that this runs fine **alongside** `booth-multiview.py`'s own
  separate sessions on the same connectors — Mutter serves both.
  **Found and fixed while building this:** the obvious approach —
  GStreamer's `videorate` element to cap the output at a fixed low fps —
  silently stalls the pipeline in `PAUSED` forever (never reaches
  `PLAYING`, never writes a frame) against a mostly-static screen, because
  `videorate` needs a couple of real timestamped buffers before it will
  emit anything, and `RecordMonitor`'s `is-recording: true` does not mean
  "frames at a fixed rate regardless of content" the way it reads — an
  idle FreeShow output can go long stretches with no new buffer at all.
  Fixed by throttling with a plain wall-clock pad probe instead (drops
  buffers arriving too soon; no preroll requirement, so the very first real
  frame still writes immediately).
- **`start-hdmi-preview-dp4.sh`** (installed as `hdmi-preview-dp4.service`)
  — DP-4 (program), reading the `ffmpeg-capture` UDP `:5002` tee (the
  "free probe" port — see `start-ffmpeg-capture.sh`) with plain `ffmpeg
  -update 1`. Not ScreenCast: `booth-multiview.py` already found DP-4
  ScreenCast damage-starved (~0-2fps, froze until a workspace switch), so
  this reuses the proven encode-tap approach instead.

**DP-1 (the booth's own monitor) is not captured** — no existing capture
path targets it, and it's the least useful preview remotely (if you're
using the dashboard at the booth, DP-1 is the screen in front of you).

## A/V sync calibration

`:5002` is a shared, exclusive (one-reader) UDP port — both the DP-4
preview capture and `av-sync-calibrate.py capture-udp`'s manual calibration
mode want it. Rather than accept that conflict, the dashboard **owns**
both consumers: `POST /api/calibrate`
(`dashboard/backend/app/calibrate.py`) stops `hdmi-preview-dp4.service`,
runs the calibration script, and restarts the preview capture afterward —
whether calibration succeeded, measured an out-of-sync result, or failed.
`av-sync-calibrate.py` also has its own independent port-stealing safety
net (kills whatever's on the port if run manually, bypassing the
dashboard) — confirmed both paths work: with `hdmi-preview-dp4.service`
not yet installed, a real calibration run correctly triggered that
built-in kill, ran to completion, and returned a real parsed result
(`verdict: no_markers` — expected outside a real calibration pattern being
on program).

## Livestream schedule panel

`ffmpeg-srt-relay.service` is deliberately **not** started at boot (see
SYSTEM-STATE.md), so `livestream-autostart.timer` is the only *automatic* start
path. A disarmed timer therefore means the Sunday stream silently never starts —
nothing else would surface that until someone noticed there was no stream — which
is why it gets a panel rather than staying CLI-only.

- Backend: `app/livestream_schedule.py`, endpoints `GET /api/livestream/schedule`,
  `POST /api/livestream/schedule` (set day/time), `POST /api/livestream/schedule/arm`.
- **Reads** go straight to `systemctl --user show -p` (structured, no parsing of a
  human-facing script). **Writes** go through `~/bin/livestream-schedule.sh`, which
  already validates the calendar spec and knows that systemd *accumulates*
  `OnCalendar=` across a unit and its drop-ins (so a drop-in must emit a bare
  `OnCalendar=` reset first, or the old time keeps firing alongside the new one).
  Duplicating that rule in Python would mean two copies of a subtle gotcha.
- **Not** routed through `units_manifest.json`: that models start/stop/restart on a
  service, and "set a recurring time" / "arm the schedule" aren't those verbs. As a
  result `ConfirmStore` (which keys on unit+action) doesn't apply either, so the
  frontend confirms *disarming* with its own modal — that's the action that can
  quietly cost a Sunday. Same precedent as `recording.py` and `calibrate.py`.
- The spec is validated twice before it can reach a unit file: a conservative
  character allowlist in `livestream_schedule.validate_spec`, then
  `systemd-analyze calendar`. Always passed as a single argv element, never
  `shell=True`. (`systemd-analyze` was confirmed to reject newline, `;`, backtick
  and `$(...)` payloads on its own; the allowlist is belt-and-braces.)
- The day/time controls only appear when the effective spec is a simple weekly
  shape. Anything richer (multiple times, date components, non-zero seconds) is
  shown read-only with a pointer to the CLI, so the UI can never silently rewrite
  a schedule someone set deliberately.
- The panel also warns if `ffmpeg-srt-relay.service` ever reads `enabled` — that
  would mean every boot goes live, the regression this arrangement removed.

Tests: `node dashboard/tests/livestream-schedule-ui-test.js` (exit 0 = pass). It
slices the schedule block out of the real `static/js/dashboard.js` and runs it against
a DOM stub, so it can't drift from the shipped code. Covers every `refreshSchedule()`
branch plus the spec parse/build helpers. It checks **behaviour, not appearance** —
this machine has no usable headless browser (no Chrome; Vivaldi strips headless;
Firefox `--screenshot` writes nothing; GNOME 46 denies the Shell screenshot D-Bus API
to unsandboxed callers), so the rendered card still wants one human glance.

## Layout

```
dashboard/
  README.md
  docs/
    agent-tools.md       — AI agent bridge design: tool list, security model
  backend/
    app/
      main.py             — FastAPI app / routes
      config.py           — reads ~/.config/soundbooth/dashboard.conf
      units.py            — loads units_manifest.json (the allowlist)
      units_manifest.json — single source of truth: units, groups, actions,
                             which actions need confirmation
      systemctl_client.py — the only place that shells out to systemctl/journalctl
      health.py            — wraps soundbooth-health.sh --json
      confirm.py           — confirm-token flow for destructive actions
      calibrate.py          — orchestrates av-sync-calibrate.py around the
                               shared :5002 port (see "A/V sync calibration")
      agent_tools.py       — the agent's tool functions + Anthropic tool
                              specs (same allowlist/confirm gates as the REST API)
      agent.py             — AgentBridge: the one shared Claude session behind
                              /ws/agent (streaming loop, tool dispatch, staging)
      auth.py               — PIN check + session dependency
    static/                 — the real frontend (FastAPI serves this directly)
      login.html / index.html / service.html
      css/dashboard.css     — shared tokens + components, ported from the mockup
      js/api.js             — fetch wrapper (same-origin, redirects to login on 401)
      js/icons.js            — inline SVG icon set (no icon font)
      js/ui.js                — shared confirm-modal / toast helpers
      js/dashboard.js, service.js, login.js — per-page logic
    requirements.txt
    dashboard.conf.example
    run.py                 — systemd entrypoint (binds host/port from config)
  systemd/
    soundbooth-dashboard.service

audio-routing/
  scripts/
    hdmi-preview-capture.py       — DP-2/DP-3 preview capture (ScreenCast)
    start-hdmi-preview-dp4.sh     — DP-4 preview capture (UDP :5002 tee)
  systemd/
    hdmi-preview.service
    hdmi-preview-dp4.service
```

## Running it locally

```
cd dashboard/backend
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
cp dashboard.conf.example ~/.config/soundbooth/dashboard.conf   # then edit it
.venv/bin/python run.py
# open http://<DASHBOARD_HOST>:<DASHBOARD_PORT>/ (defaults to 127.0.0.1:8420)
```

For real HDMI tiles (not the "not available" placeholder), the preview
capture scripts need to be running too — neither is installed as a service
yet, run them directly to try it:

```
~/bin/hdmi-preview-capture.py &          # or audio-routing/scripts/ path if not yet deployed to ~/bin
~/bin/start-hdmi-preview-dp4.sh &
```

## Getting an API key

The agent chat panel calls the Anthropic API, which is billed pay-as-you-go
and separate from any Claude.ai subscription.

1. Sign in at <https://console.anthropic.com/> and create (or join) an
   organization.
2. **Billing → ** add a payment method and a small amount of prepaid credit.
   Set a low monthly spend limit as a backstop — a booth troubleshooting
   chat is a few thousand tokens, cents per session on `claude-sonnet-5`
   ($3 / $15 per million in / out).
3. **API keys → Create key.** Give it a name like `soundbooth-dashboard`.
   Copy the `sk-ant-...` value now — it's shown once. A workspace-scoped key
   lets you track and cap this dashboard's usage on its own and revoke it
   without touching anything else.
4. Put it in `~/.config/soundbooth/dashboard.conf`:
   ```
   ANTHROPIC_API_KEY=sk-ant-...
   ```
   then restart the dashboard (`systemctl --user restart soundbooth-dashboard`
   once it's installed, or just re-run `run.py`). Until a real key is set the
   chat panel loads but stays disabled with an "add a key" notice.

## Security model

Everything the dashboard (and later, the agent) can do to the live system
routes through `units_manifest.json`: only listed units, only listed
actions per unit. Anything the manifest marks `"confirm"` requires a staged
token plus a second, explicit call — no single request (from a browser click
or from the agent) ends the livestream or starts it by itself. See
`docs/agent-tools.md` for why this matters more once the dashboard is
reachable from the LAN subnet, not just the booth PC.

The dashboard's own failure must never affect production audio/video — it
only reads `systemctl`/`journalctl`/health output and calls
`systemctl --user <action> <allowlisted unit>`; it is not a dependency of
`soundbooth.target` and nothing in the audio/video chain waits on it.

### Local auto-login

The booth PC's own dashboard-viewer window (`start-booth-dashboard-view.sh`)
skips the PIN screen — the operator is already sitting at a machine with no
OS login of its own (`AutomaticLoginEnable=true` in gdm3), so a second
credential on top of that is friction without real security benefit, while
the PIN still matters for anyone reaching the dashboard over the LAN.

This is **not** an IP check: testing on the real machine showed at least one
local browser context's requests to `127.0.0.1` arrive at the server showing
the machine's real LAN IP instead of loopback (cause unresolved, no proxy
configured) — so "trust requests from 127.0.0.1" would have been unreliable
here. Instead, `LOCAL_TOKEN` in `dashboard.conf` (same trust tier as the PIN
and session secret) is passed once in the local viewer's launch URL; the
page exchanges it for a normal session via `POST /api/login/local` on load
and immediately scrubs it from the address bar. Leave `LOCAL_TOKEN` unset to
require the PIN everywhere, including locally.
