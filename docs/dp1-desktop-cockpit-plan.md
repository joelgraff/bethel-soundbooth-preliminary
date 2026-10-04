# DP-1 desktop cockpit plan

Investigation/planning note, not architecture truth — see `SYSTEM-STATE.md`
for what's actually live. Written 2026-09-27 from a same-day planning
conversation (see `STATUS.md`'s 2026-09-27 entries for the incident that
prompted it). Edit this file directly as the plan evolves rather than
starting a parallel doc.

## Problem

DP-1 (the booth's own ultrawide, `SAM S34CG50`) is the operator's main
working view, but the things that matter during a live service are spread
across a separate workspace (the full web dashboard, workspace 2, reached by
Super+PgDn) and a heavyweight app (PTZOptics CMP) that's laggy and hard to
resize. Nothing critical is glanceable without switching context.

## Decisions made

- **Tiling:** disable Ubuntu's built-in `tiling-assistant@ubuntu.com`
  extension; keep `tilingshell@ferrarodomenico.com` (already installed,
  already in active use — visible in `gnome-shell` logs) as the one tiling
  extension. Running both risked conflicting keybinds/drag behavior.
  **Not yet executed** — GNOME Shell extension changes were deferred while
  this session coincided with a live service; do this next time the booth
  is between services (`gnome-extensions disable tiling-assistant@ubuntu.com`,
  takes effect immediately, no session restart needed for a plain disable).
- **Widget approach:** small, purpose-built pages (Electron/Vivaldi `--app=`
  windows, same technique already used for the dashboard and FreeShow),
  not a new GNOME Shell extension and not overlays glued onto the existing
  dashboard page.
- **Locking windows to DP-1:** left aside. If everything needed is already
  visible and correctly tiled, there's nothing to drag in the first place —
  revisit only if drift becomes an actual problem in practice. (For the
  record: no true OS-level "pin to monitor" exists in Mutter; the fallback
  if this comes back is a periodic watcher reusing the `wmctrl -e`
  reposition technique already proven in `start-freeshow.sh` /
  `start-booth-browser.sh`, not a new Shell extension — the "extension JS
  doesn't hot-reload" gotcha in `SYSTEM-STATE.md` makes that a much slower
  iteration loop.)
- **Per-widget HTTP ports (e.g. camera control on :3000, DAW on :3001, AI
  agent on :3002)** — raised as a rough idea, explicitly **out of scope**
  for this plan. Worth a look later; not designed here.

## Zoning

Two zones, not six equal tiles:

- **Primary zone (large):** FreeShow — the dominant app. Spotify shares this
  zone; it works well in a narrower **portrait** configuration, so it can
  likely sit alongside FreeShow rather than needing an alt-tab swap.
- **Widget column (narrow, fixed, always visible):**
  1. Camera control — 4-directional + home + named presets, **no video
     feed** (see below)
  2. Livestream + DP output tiles (**built**, see "Built" section)
  3. Subsplash confirmation view — pinned Vivaldi window on
     `dashboard.subsplash.com/-d/#/media/live` (already the documented
     livestream-verify URL in `SYSTEM-STATE.md`) — confirms the stream is
     actually reaching Subsplash, distinct from the SRT-relay preview tile
     which only shows the local encode leg
  4. AI chat agent — reuses the existing `/ws/agent` bridge
     (`dashboard/backend/app/agent.py`), stripped of the rest of the
     dashboard's chrome

Exact pixel sizing is a tuning step once the zone is actually being used,
not a planning decision.

## Camera control widget — the one real new backend piece

Today, camera control goes entirely through PTZOptics CMP (the full app) —
nothing in this repo talks to the camera's control protocols directly.
`~/.config/soundbooth/camera.conf` only holds the IP. The camera
(PT12X-SDI-xx-G2) documents two control surfaces per `SYSTEM-STATE.md`:
VISCA-over-IP (`:5678`) and an HTTP interface (`:80`). Building this needs:

1. A short research step confirming which protocol (or both) actually
   supports pan/tilt/zoom + preset recall + home on this specific
   camera/firmware (SOC v6.2.82) — not assumed.
2. A small dashboard backend module speaking that protocol directly to the
   camera, bypassing CMP entirely for this use case.
3. A minimal frontend: direction pad + home + named presets, no video
   element at all.

This is also the actual fix for "CMP is laggy and hard to resize" — the
point isn't to fix CMP's window, it's to stop needing CMP for day-to-day
preset recall. CMP stays for full-preview framing/setup work, which doesn't
happen mid-service.

## Build order

1. Disable `tiling-assistant`; define the two zones in `tilingshell`.
   *(pending — see above)*
2. Subsplash status widget — zero backend work, a pinned browser window at
   an existing URL. *(pending)*
3. DP-1 placement tuning for pinned widgets once zones exist. *(pending —
   "locking" deliberately left aside, see Decisions)*
4. **Livestream + DP-monitors widget — built this session, see below.**
5. AI chat widget — reuses `/ws/agent`, new frontend only. *(pending)*
6. Camera control widget — the real new backend piece, above. *(pending)*
7. FreeShow/Spotify zone — mostly a tiling/placement config, not new code.
   *(pending)*

## Built (2026-09-27)

**Livestream cockpit widget** — `dashboard/backend/static/widget-livestream.html`
+ `js/widget-livestream.js`. One card (relay status lamp/label + a single
Start/Stop button, same confirm-token flow as the main dashboard's quick
action) plus the four-tile DP output grid (DP-2/DP-3/DP-4/LIVESTREAM).
No new backend endpoints — reuses `/api/services`, `/api/services/{unit}
/start|stop`, `/api/outputs/{display}`, exactly like the main dashboard.

Also extracted `js/hdmi-grid.js` out of `dashboard.js` (the four-tile grid
was duplicated logic waiting to happen the moment a second page needed it)
— both `index.html` and the new widget now share one implementation.

Launcher: `audio-routing/scripts/start-widget-livestream.sh`, modeled on
`start-booth-dashboard-view.sh` (own Vivaldi profile, same `LOCAL_TOKEN`
auto-login bootstrap, `--class=SoundboothWidgetLivestream`). Installed to
`~/bin` and wired into `install-booth-autostart.sh`'s copy step so it can't
silently drift out of sync the way `start-booth-browser.sh` once did (see
`STATUS.md`, 2026-09-20 code review finding) — **deliberately no autostart
`.desktop` entry yet**, since exact DP-1 zone placement isn't finalized.
Run manually to test: `~/bin/start-widget-livestream.sh &`.

**Verified (backend-level only, this session):** JS syntax (`node --check`)
on all three touched/added files; the live `soundbooth-dashboard.service`
correctly serves `widget-livestream.html`, both new JS files, and still
serves the unchanged main dashboard after the `hdmi-grid.js` extraction
(all `200`). **Not yet done:** an actual visual/GUI check (launching the
widget window, confirming layout, clicking Start/Stop for real) — held back
because this work landed while a service was in progress and launching a
new on-screen window wasn't worth the risk of an on-screen surprise mid-
service. Do that first, before relying on this widget live.
