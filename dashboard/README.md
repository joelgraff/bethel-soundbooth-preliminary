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

Not working yet / deliberately honest placeholders in the UI:
- `/ws/agent` is still a stub — the chat panel connects, shows the backend's
  "not wired up yet" message, and leaves the input disabled rather than
  faking a conversation; see `docs/agent-tools.md` for what's left

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
      agent_tools.py       — tool functions for the future agent bridge
                              (same allowlist/confirm gates as the REST API)
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
