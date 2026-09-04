# Soundbooth Project — Cross-Session Status

Updated: 2026-09-04 (PreSonus USB protocol errors; CMP restart loop gated on real camera stream)

## Current State (2026-09-04 — PreSonus USB protocol errors; CMP restart loop gated on real camera stream)

- [x] **FOH silent (Spotify playing, nothing at the board) — root cause was
  a flaky USB link to the 32SX, not routing.** All software checks passed
  (`soundbooth-health.sh` foh-graph PASS, Spotify unmuted 54%, Mixer 100%,
  `parec`/`aplay` bridge alive, real signal measured on `Mixer.monitor`
  — RMS ~430/32767). Kernel log showed the 32SX failing enumeration twice
  at boot (`usb 1-1: device descriptor read/64, error -71`) before
  succeeding on a 3rd attempt, matching 11 failed
  `presonus-foh-bridge.service` restarts ("Cannot get card index for
  S32SX"). Even after it "settled," `amixer -c 3 cget numid=1` (the board's
  `StudioLive Internal Clock Validity` control) returned **"Protocol
  error"** — the board was never actually locking to the USB clock, so
  `aplay` could hand it samples with zero reported xruns while the board
  rendered nothing. Not the known ATEM-shares-a-USB-bus issue (32SX is on
  bus 1 root port 1; ATEM is on bus 3) — a genuinely marginal
  cable/port/connection to the 32SX itself.
  - **Fix: power-cycling the 32SX board resolved it** (confirmed by the
    operator). If it recurs, next steps are swapping the USB cable and/or
    trying a different port.
- [x] **camera-management.service (CMP / PTZOptics Camera Management
  Platform) was crash/restart-looping — distracting flashing on the booth
  screen — whenever the PTZ camera has no active stream.** Two compounding
  causes: (1) CMP's own GPU/zygote process dies on every forced
  stop/restart while the camera is off (`status=5/TRAP`, "GPU process
  isn't usable. Goodbye."); (2) `camera-management-watch.service`
  force-restarts the service every ~150-180s because `:9999` never binds
  with no camera to transcode — which it was treating as "stuck," but is
  actually expected with the camera off.
  - **Fix:** new `~/bin/start-camera-management.sh` wraps the real binary
    and waits for an actual RTSP frame pull to succeed before exec'ing
    it — no window ever opens, nothing crashes, while the camera has no
    stream. `camera-management.service`'s `ExecStart` now points at this
    wrapper. **Ping alone is not a valid reachability check for this
    camera** — same gotcha already documented in
    `livestream-camera-watch.sh`: its RTSP server keeps answering
    DESCRIBE/handshake requests with the video encoder off, so the check
    must pull a real frame via `ffmpeg -rtsp_transport tcp ... -frames:v
    1`. Verified live: ping succeeds against the camera right now, but the
    frame-probe correctly returns "no stream." Updated
    `camera-management-watch.sh` to use the same frame-probe instead of
    treating `:9999` unbound as automatically "stuck," so it no longer
    force-restarts CMP while the camera is legitimately off.
  - Verified: service settles at `NRestarts=0`, wrapper process alone
    (no Electron/GPU children) polling quietly, watcher stays quiet too.
  - Files: `audio-routing/scripts/start-camera-management.sh` (new),
    `audio-routing/scripts/camera-management-watch.sh`,
    `audio-routing/systemd/camera-management.service`.

## Current State (2026-09-01 — Dashboard local auto-login)

- [x] **Local dashboard viewer now skips the PIN screen**, per direction —
  the booth PC already auto-logs-in at the OS level
  (`AutomaticLoginEnable=true`/`AutomaticLogin=soundbooth` in
  `/etc/gdm3/custom.conf`, confirmed), so a second credential just for the
  local dashboard view added friction with no real security benefit; the
  PIN still gates LAN access.
- [x] **Deliberately not an IP check.** While verifying, found that at
  least one local browser context's requests to `127.0.0.1:8420` arrive at
  the server showing the machine's real LAN IP (`192.168.2.200`) instead of
  loopback — no proxy configured, cause not fully root-caused (traced it as
  far as: it's not the dashboard-viewer's own dedicated process tree, which
  *does* correctly show `127.0.0.1`; some other/older browser context on
  the same machine is also polling the API over the LAN-facing address for
  reasons unresolved). Built the bypass on a shared secret instead
  (`LOCAL_TOKEN` in `dashboard.conf`, same trust tier as the PIN/session
  secret) so it's unaffected by whatever that is.
- [x] **New `POST /api/login/local`** (`dashboard/backend/app/auth.py`,
  `main.py`) — fail-closed like `check_pin`, exchanges a valid
  `LOCAL_TOKEN` for a normal session. `start-booth-dashboard-view.sh`
  reads the token from `dashboard.conf` and passes it once in the launch
  URL (`?local_token=...`); `static/js/api.js`'s `bootstrapLocalToken()`
  exchanges it on page load and immediately scrubs it from the address bar
  via `history.replaceState`. Generated a real token, added it to the live
  `dashboard.conf`, deployed, restarted `soundbooth-dashboard.service`.
- [x] **Verified end-to-end**: no token/cookie → 401; wrong token → 401;
  correct token → 200 + session cookie works for subsequent calls; relaunched
  the real `start-booth-dashboard-view.sh` and confirmed via the live
  service journal it exchanged the token and loaded fully authenticated
  with no PIN prompt.

## Current State (2026-09-01 — FreeShow window fix, multiview retired, dashboard on workspace 2)

- [x] **Diagnosed and fixed FreeShow's main window spawning invisible.** Matched
  the same "dead zone / remote TV" pattern documented in memory
  (`docs/display-investigation-2026-07-12.md`): the window had landed on
  DP-4 (a remote sanctuary TV, not the booth seat) at x=980,y=1174.
  Repositioned it onto DP-1 live (`wmctrl -e` + `-a`) and, per direction,
  **added permanent force-placement to `start-freeshow.sh`** (same
  re-assert-for-~20s pattern `start-booth-browser.sh` already uses),
  matching the *exact* title `"FreeShow"` only — the Primary/Stage output
  windows must stay on DP-2/DP-3, never get swept onto DP-1. Deployed to
  `~/bin/start-freeshow.sh`; did not restart the already-running FreeShow
  instance (already manually fixed, didn't want to disrupt a live app).
- [x] **Retired booth multiview** ("the DP viewer"), per direction — its
  role (glanceable preview of the outputs) is now the web dashboard's HDMI
  preview tiles. Stopped the running process, removed its autostart +
  `~/.local/share/applications` entries (live and repo source), removed
  `soundbooth-health.sh`'s `check_multiview` (~110 lines) and every other
  multiview reference in that script (header comment, hints, autostart
  file list), updated `install-booth-autostart.sh`'s manifest. Did **not**
  delete `booth-multiview.py`/`start-booth-multiview.sh` themselves —
  kept in the repo, just no longer autostarted or health-checked, in case
  ever wanted again.
- [x] **Web dashboard now opens in Vivaldi on GNOME workspace 2**, per
  direction — replacing multiview's old spot exactly. New
  `start-booth-dashboard-view.sh` (Vivaldi `--app=http://127.0.0.1:8420/`,
  own profile `~/.config/vivaldi-dashboard`, `--class=SoundboothDashboard`),
  new `soundbooth-dashboard.desktop` (autostart + app entry), new
  `configure-dashboard-workspace.sh` (replaces
  `configure-multiview-workspace.sh`, deleted). Workspace-2 placement reuses
  the same Wayland-native Shell extension multiview used
  (`soundbooth-multiview-workspace@soundbooth`), repurposed in place to
  title-match "Soundbooth Control" (Vivaldi `--app=` mode titles the window
  after the page `<title>`) instead of "Soundbooth Multiview," plus Auto
  Move Windows as a backup path (`soundbooth-dashboard.desktop:2`).
  **Found while verifying:** `gnome-extensions disable/enable` — and even
  the proper `org.gnome.Shell.Extensions` D-Bus `EnableExtension`/
  `DisableExtension` calls — report success but do **not** reliably reload
  already-loaded extension JS in this GNOME 46 session (`ReloadExtension`
  is advertised in the D-Bus introspection but not actually implemented;
  confirmed via `GetExtensionErrors` returning empty and `gnome-extensions
  show` still displaying the old name/description after reload attempts).
  The Auto Move Windows backup path **is** gsettings-data-driven (no code
  to reload) and appears to be what's actually placing the window on this
  already-running session (workspace 2 became and stayed the active
  workspace across two independent test launches); the Shell extension's
  updated code will take over cleanly on the next login/reboot. Documented
  in SYSTEM-STATE.md.
- [x] **Found and fixed a real live bug while re-running health checks
  after all this:** ffplay's audio had drifted onto Mixer/FOH instead of
  the HDMI TV (`wpctl status` showed `ffplay → Mixer:playback_FL/FR`,
  should be `→ HDMI 1`). Fixed with the documented remedy,
  `systemctl --user restart ffmpeg-display.service`; confirmed re-routed to
  HDMI 1 afterward. Root cause not confirmed — first noticed right after
  this session's earlier service restarts, but multiview/dashboard changes
  don't touch audio routing, so plausibly unrelated/pre-existing; worth
  watching for recurrence.
- [x] **`soundbooth-health.sh` clean**: 47 pass / 0 warn / 1 fail (ATEM
  unreachable — expected outside service hours) after all of the above.
  Deployed the updated script to `~/bin/soundbooth-health.sh`.

## Current State (2026-09-01 — Control dashboard: deployed as real systemd services)

- [x] **Installed and enabled all three dashboard services for real**
  (`systemctl --user enable --now`, all `graphical-session.target` — not
  `soundbooth.target`, deliberately, so the dashboard's own lifecycle stays
  independent of the audio/video chain):
  - `hdmi-preview.service` (DP-2/DP-3 capture)
  - `hdmi-preview-dp4.service` (DP-4 capture)
  - `soundbooth-dashboard.service` (backend + frontend, bound `0.0.0.0:8420`
    — the soundbooth LAN subnet, per the earlier access-model decision)
  Scripts copied to `~/bin/`, units copied to `~/.config/systemd/user/`.
- [x] **Real config created** at `~/.config/soundbooth/dashboard.conf`
  (mode 600) with a freshly generated PIN and session secret — not a
  placeholder. **PIN is not written here or in any repo file** — operator
  has it from the session that generated it; change it any time by editing
  that conf file and restarting `soundbooth-dashboard.service`.
- [x] **Verified against the live, persistent services** (not ad-hoc test
  processes this time): dashboard reachable on the LAN, real PIN login
  works, health check live (58 pass/0 warn/1 fail at verification time —
  ATEM unreachable, expected outside service hours), DP-3/DP-4 previews
  showing fresh real frames, DP-1 correctly "not captured", DP-2 correctly
  reported stale (that output's screen genuinely hasn't changed since
  capture started — not a bug).
- [ ] Still not done: Claude Agent SDK wiring behind `/ws/agent` (the last
  major stubbed piece — see `dashboard/docs/agent-tools.md`).

## Current State (2026-09-01 — Control dashboard: HDMI preview capture + A/V calibration)

- [x] **Built real HDMI live preview capture** for the dashboard's output
  tiles: `audio-routing/scripts/hdmi-preview-capture.py` (DP-2/DP-3, via
  independent `org.gnome.Mutter.ScreenCast` `RecordMonitor` sessions — same
  technique as `booth-multiview.py`, confirmed to run **alongside** it
  without conflict) and `start-hdmi-preview-dp4.sh` (DP-4, via the
  `ffmpeg-capture` UDP `:5002` free-probe tee). **DP-1 intentionally not
  captured** (per direction — lowest value remotely, no existing capture
  path). Neither installed as a service yet; both proven against the real
  live system (real JPEGs captured from the actual dark/idle sanctuary —
  DP-4 showed the real program feed, DP-2/DP-3 showed the real FreeShow
  outputs).
- [x] **Real bug found and fixed while building it:** the obvious design
  (GStreamer's `videorate` to cap output at a fixed low fps) silently stalls
  the pipeline in `PAUSED` forever against a mostly-static screen — never
  reaches `PLAYING`, never writes a frame, no error. `videorate` needs a
  couple of real timestamped buffers before it emits anything, and
  `RecordMonitor`'s `is-recording: true` does not force a fixed frame rate
  regardless of content the way it reads. Verified by isolating the cause
  (briefly stopped `booth-multiview.py` to rule out session contention —
  restored immediately after, confirmed healthy) before finding the real
  culprit. Fixed with a plain wall-clock pad probe throttle instead — no
  preroll requirement, first real frame still writes immediately.
- [x] **Rolled `av-sync-calibrate.py` into the dashboard**, per direction:
  `:5002` is a shared, exclusive (one-reader) UDP port that both the DP-4
  preview capture and the calibration tool's manual `capture-udp` mode
  want. `POST /api/calibrate` (`dashboard/backend/app/calibrate.py`) now
  owns both consumers — stops `hdmi-preview-dp4.service`, runs the
  calibration script, restarts the preview capture after, regardless of
  outcome. Confirmed against the real system: a real calibration run
  (against the actual `:5002` tee) correctly triggered the script's own
  built-in port-stealing safety net (since the preview service isn't
  installed yet), completed, and returned a real parsed result (`verdict:
  no_markers` — expected, no calibration pattern on program right now).
  Deliberately **read-only**: reports the measured offset + suggested
  delay, never writes it to the live config or restarts the program
  encode — applying a fix stays a manual step.
- [x] **Frontend wired to all of the above:** the 4 HDMI tiles poll real
  captured JPEGs every ~2.5s (DP-1 stays an honest "not captured"
  placeholder); a new "Run A/V Sync Check" button on the dashboard calls
  `/api/calibrate` and renders the real verdict/offset/suggested delay.
- [ ] **Not yet done:** installing/enabling `hdmi-preview.service` and
  `hdmi-preview-dp4.service` as real systemd `--user` units (written, not
  deployed); the dashboard backend itself is still not installed as a
  service either (from the previous session).

## Current State (2026-09-01 — Control dashboard: frontend wired to backend)

- [x] **Converted the static design mockup into a real, working frontend**
  at `dashboard/backend/static/` (plain HTML/CSS/JS, no build step — served
  directly by the FastAPI backend) and wired every page to the real API
  from the earlier scaffolding session: PIN login, live health banner +
  troubleshooting list, grouped services with real restart/start/stop
  controls, a service detail page, and a service-log viewer.
- [x] **Kept the placeholders honest instead of faking data:** the HDMI
  preview tiles show real DP-1..4 labels but say "preview not available
  yet" (the capture subsystem isn't built); the AI agent chat panel
  connects over `/ws/agent`, shows the backend's real "not wired up yet"
  message, and leaves the input disabled — no scripted fake conversation.
  The service detail page only shows fields the API actually returns
  (active/sub state, result), not fabricated uptime/CPU numbers.
- [x] **Confirm-token flow has a real UI now:** starting/stopping the
  livestream relay pops an actual confirm dialog with the manifest's
  warning text before the second, confirmed request fires.
- [x] **Smoke-tested end-to-end** (test PIN, cleaned up after): all static
  pages 200, `/api/session` correctly reflects login state, `/api/services`
  returns real status for all 13 units, `/api/outputs/DP-1` returns the
  honest stub, and a real WebSocket client received the `/ws/agent` stub
  message over an authenticated session cookie. Also verified: every
  `getElementById` in the JS has a matching id in its HTML (caught nothing,
  but worth having as a check), all JS files pass `node --check`, unknown
  API and static paths both 404 correctly. Fixed one real bug found during
  this pass — a health-issue "Quick Fix" button could fire against the
  wrong check once any earlier check lacked a mapped fix (index misalignment
  between the rendered buttons and the full issues list).
- [ ] **Not yet built:** the actual Claude Agent SDK wiring behind
  `/ws/agent`, HDMI live-preview capture, and installing/enabling
  `dashboard/systemd/soundbooth-dashboard.service` for real.

## Current State (2026-09-01 — Control dashboard: design + backend scaffolding)

- [x] **Designed a web control dashboard** for the booth PC: system health at
  a glance, grouped service start/stop/restart controls, a 4-way HDMI output
  preview grid (DP-1..4), an AI agent chat panel, and troubleshooting/logs —
  aimed at non-technical Sunday volunteer operators. Two-screen static
  mockup (Dashboard + Service Detail) built as a Claude Design canvas.
- [x] **Access model decided:** reachable from the booth PC *and* the
  soundbooth LAN subnet (confirmed password-protected, separate from guest
  Wi-Fi) — gated by a PIN. Controls (start/stop/restart) are in scope from
  the first real build, not a later phase.
- [x] **AI agent decision:** using **Claude**, not Grok, as the dashboard's
  agent going forward. Because the panel is LAN-reachable (not just
  physically-at-the-booth like today's terminal `sunday-grok.service`), the
  web-facing agent gets a **fixed, code-enforced toolset** — not the shell
  access the terminal session has — mirroring exactly what the dashboard's
  own buttons can do. One shared session (no per-device agent instances).
  Full tool list + reasoning: `dashboard/docs/agent-tools.md`.
- [x] **Backend scaffolded** at `dashboard/backend/` (FastAPI): PIN-gated
  session auth, `GET /api/health` (wraps `soundbooth-health.sh --json` —
  already supported that flag, no script changes needed), `GET
  /api/services` (live status of every unit in
  `dashboard/backend/app/units_manifest.json` — the single allowlist shared
  by the REST API and the future agent tools), restart/start/stop routes,
  log tail, and a **confirm-token gate** for anything the manifest marks
  destructive (currently just `ffmpeg-srt-relay.service` start/stop —
  stopping it ends the live Subsplash broadcast immediately). `/ws/agent` is
  a stub; the actual Claude Agent SDK wiring is not done yet.
- [x] **Smoke-tested locally** (booth PC, test PIN, cleaned up after):
  unauthenticated/wrong-PIN requests correctly 401; `/api/health` returned
  real live output (**58 pass / 0 warn / 1 fail** at test time — ATEM not
  reachable at 192.168.2.252, expected outside service hours); `/api/services`
  returned real `systemctl --user` status for all 13 units; a restart request
  for a unit not on the manifest was rejected before ever calling
  `systemctl`; a stop request for the livestream relay correctly staged a
  confirmation token instead of executing. No real restart/start/stop was
  invoked against any production unit during testing.
- [x] Installed `python3.12-venv` / `python3-pip` system packages (were
  missing entirely) so the backend's venv could be created.
- [ ] **Not yet built:** frontend wired to the API (mockup is static only),
  HDMI live-preview capture (plan: reuse `booth-multiview.py`'s GNOME
  ScreenCast / ffmpeg UDP-tee pipeline rather than new capture code), the
  Claude Agent SDK integration behind `/ws/agent`, and the systemd unit
  (`dashboard/systemd/soundbooth-dashboard.service`) is written but not
  installed/enabled.
- Added a `dashboard/` row to `AGENTS.md`'s "Where work goes" table.

## Current State (2026-08-30 — Sunday service boot)

- [x] `~/bin/soundbooth-health.sh` at 08:16 CDT: **59 pass / 1 warn / 0 fail**.
- [x] Core path up: Presonus + ATEM USB, `/dev/video0`, DP-1..4, ffmpeg-capture (~88% CPU), ffplay on DP-4, FOH ALSA bridge, Mixer default, livestream relay **active**, multiview on workspace 2, session apps (Spotify / FreeShow / Vivaldi).
- [x] **1 WARN (non-blocking):** CMP `camera-management.service` active but RTSP-MPEG websocket `:9999` not listening yet (~1 min after start). Watcher grace is 150s (`camera-management-watch.service`). PTZ IP preview only — program is still SDI → ATEM. Manual if still blank after ~3 min: `systemctl --user restart camera-management`.
- Stay ready this session: audio routing, FFmpeg SRT/ffplay DP-4, ATEM, FreeShow, displays.

## Current State (2026-08-23 — livestream auto-ends when the camera is powered off)

- [x] **Follow-up to the split above:** operators power the camera off well
  before the booth PC/ATEM at end of service, so `/dev/video0` never
  disappears and can't signal "camera off". Confirmed the PTZOptics camera
  at 192.168.1.202 is the *same physical unit* feeding the ATEM's SDI
  program input, so its network reachability is a safe proxy for "camera
  lost power" — no false-positive risk from just showing a dark scene.
- [x] **Built `livestream-camera-watch.service`** (`livestream-camera-watch.sh`):
  pings the camera every 15s; after 60s of sustained unreachability, calls
  `stop-live-stream.sh` automatically (once per outage). Never restarts the
  stream when the camera comes back — resuming stays a deliberate
  `~/bin/start-live-stream.sh`. Added to `soundbooth-health.sh`
  `EXPECTED_SERVICES` (always-on watcher, independent of whether the stream
  itself is live).
- [x] **Verified end-to-end** with a simulated unreachable IP and short
  grace period: relay stopped cleanly after the grace period, capture + TV
  unaffected, no repeat/spam stop calls while camera stayed down.
- [ ] Still deferred: ATEM Mini button → `stop-live-stream.sh`.

## Current State (2026-08-23 — livestream can now be ended independently)

- [x] **Problem:** Subsplash keeps a live event open for up to 8 hours unless
  the stream is explicitly ended from our side. There was no quick, safe way
  to do that — `ffmpeg-srt.service` was one process that both fed Subsplash
  (SRT) AND fed the sanctuary TV (local UDP), so stopping it to end the
  stream also blacked out the TV.
- [x] **Split `ffmpeg-srt.service` into two independent services** (old
  service/script removed, not just renamed):
  - `ffmpeg-capture.service` (`start-ffmpeg-capture.sh`) — owns ATEM
    `/dev/video0`, always-on, encodes once, tees to 4 local UDP ports:
    `:5000` DP-4 display, `:5001` multiview, `:5002` av-sync-calibrate probe,
    `:5003` **new** — dedicated feed for the livestream relay.
  - `ffmpeg-srt-relay.service` (`start-ffmpeg-srt-relay.sh`) — the *only*
    process that talks to Subsplash. Reads `:5003`, stream-copies (no
    re-encode, ~2.6% CPU) to SRT. Stopping it ends the live event on
    Subsplash's side immediately without touching capture or the TV.
  - Each local UDP port is unicast (exclusive, one reader) — confirmed the
    live conf actually uses unicast `127.0.0.1`, not the multicast address
    the old script defaulted to, so the relay needed its own port rather
    than sharing `:5000` with ffplay.
- [x] **New operator commands:** `~/bin/stop-live-stream.sh` (end the stream
  now) and `~/bin/start-live-stream.sh` (resume it) — just start/stop
  `ffmpeg-srt-relay.service`. Capture + DP-4 TV are unaffected either way.
- [x] **`ffmpeg-srt-relay.service` added to `soundbooth-health.sh`'s
  `OPTIONAL_SERVICES`** (like Ardour) — silent when stopped between services,
  PASS when live. Its absence is not a health failure.
- [x] **Found + fixed while testing:** ffmpeg's SIGTERM handler exits 255
  even on a clean stop, which made `systemctl stop` show as "failed" instead
  of a clean stop on both `ffmpeg-capture.service` and
  `ffmpeg-srt-relay.service` — added `SuccessExitStatus=255` to both units so
  an intentional stop reads as a clean "inactive", not an alarming "failed".
- [x] **Cutover done live** (with explicit confirmation the Sunday service
  had ended, stream had been running since 08:16 CDT): stopped old
  `ffmpeg-srt.service`, brought up the split services, ran
  `soundbooth-health.sh` (59 pass / 0 warn / 0 fail with stream live, 58/0/0
  with it intentionally stopped), verified TV + capture stayed up through a
  stop/start/stop cycle of the relay. Stream left **stopped** at the end of
  this session (service was over).
- [ ] **Not yet built:** tying `stop-live-stream.sh` to a physical ATEM Mini
  button press. Deferred by request — command-line control first, hardware
  trigger as a follow-up (candidate approach: poll the ATEM's own unused
  Stream/Record button state over its control protocol, since this booth
  streams via ffmpeg/SRT rather than the ATEM's native encoder).
- Renamed throughout (scripts, systemd units, health check, WirePlumber
  comments, av-sync-calibrate, Sunday Grok session check): `ffmpeg-srt` →
  `ffmpeg-capture` for the capture/local-only process. `ffmpeg-srt-watch.service`
  keeps its name but now watches `ffmpeg-srt-relay.service` instead.

## Current State (2026-08-16 — Sunday service)

- [x] Health: **55 pass / 0 warn / 0 fail**. Encode, DP-4 ffplay, FOH bridge, multiview, session apps up.
- [x] **CMP detected PT12X at 192.168.1.202 but showed no video.** Phone PTZ app OK.
  - Snapshot path is empty (`/snapshot.jpg` Content-Length 0). Switching to RTSP-MPEG removed the error GIF but stayed blank.
  - Real RTSP-MPEG fault: packed AppImage `import("get-port")` → `ENOTDIR` on `app.asar/node_modules/get-port`. No ffmpeg, no `:9999`.
  - Fix: extracted AppImage + unpacked `app.asar` to `~/AppImage/Camera-Management-Platform-1.9.7.extracted/`; unit runs that binary; loosened ffmpeg flags (`-timeout 3` / 250M analyze were also fatal). Verified: ffmpeg 1080p→mpeg1, WS `:9999`, renderer connected.
  - Unit source: `audio-routing/systemd/camera-management.service`. WantedBy=`graphical-session.target` (was a pasted install snippet on `default.target`).

## Current State (2026-08-02 — av-sync-calibrate tool validated)

## Current State (2026-08-02 — av-sync-calibrate tool validated)

- [x] **Confirmed the A/V sync calibrator actually works, not just that it
  runs.** Synthetic mode: measured a known injected 250ms delay to within
  15ms, zero variance across all pairs — detector + production filter logic
  confirmed sound. `capture-udp`: confirmed working end-to-end against the
  real live encode (captured `:5002`, correctly reported `no_markers` with
  no cal pattern on program).
- [x] **Fixed 2 UX bugs in `audio-routing/scripts/av-sync-calibrate.py`**
  (deployed to `~/bin/av-sync-calibrate.py`):
  1. `capture-udp`/`capture-atem` printed hundreds of raw
     `non-existing PPS`/`decode_slice_header error` lines to the console —
     looked like a fault but is normal mid-GOP-join noise already discarded
     by `+discardcorrupt` (captured files decode with zero errors). Now
     collapsed into one summary line.
  2. Synthetic mode printed a misleading "suggested delay: 0.0s" — an
     artifact of testing against an intentionally injected delay, not a real
     recommendation. Now prints `n/a in this mode` with an explanation.
- [ ] **Documented, unverified caveat**: live-mode offset measurement uses
  `frame_index / fps` for video timing, not real PTS. This ATEM has been
  observed to drift frame rate mid-session (30→24fps, seen in ffmpeg-srt
  journal same day) — could skew a live capture-udp/capture-atem measurement
  without warning. Not reproduced; flagged in code + skill doc for future
  live calibration sessions to watch for (inconsistent offsets across pairs
  = suspect this).
- See `.grok/skills/av-sync-calibrate/SKILL.md` for full detail.

## Current State (2026-08-02 post-reboot — audio confirmed + gain re-tuned)

- [x] **Audio confirmed working at the board after reboot.** Both the WirePlumber
  volume fix and the ALSA-bridge stability held across the reboot.
- [x] **Board preamp/gain trim confirmed to do nothing for this channel** — expected,
  since USB return channels are digital and bypass the analog preamp stage. Not
  a bug. **The board's channel fader is the correct control** and works fine.
- [x] **Gain staging re-tuned by ear (operator, via pavucontrol) now that the FOH
  path passes clean unity gain:** old `ensure-audio-routes.sh` defaults
  (`FREESHOW_VOLUME_PCT=150`, `SOFTWARE_VOLUME_PCT=50`) were tuned to compensate
  for the broken/attenuated pre-fix signal and now clip hard. New defaults:
  **both 33%**. FreeShow's own in-app volume stays at 1.0 (unchanged);
  Spotify's pavucontrol slider matches its PipeWire volume directly. Deployed
  to `~/bin/ensure-audio-routes.sh` and applied live. Docs updated:
  `SYSTEM-STATE.md` audio policy section, `portal/content/quick-reference.md`.
- [ ] **Still open: native PW playback path ALSA XRUN** (see evening entry below)
  — not blocking since the bridge is stable and confirmed working; pick up
  separately when convenient, not urgent.
- [x] **`ffmpeg-srt.service` fixed (2 unrelated bugs, both found via health check
  after reboot):**
  1. **systemd ordering cycle** — `ffmpeg-srt-watch.service` had a redundant
     `WantedBy=graphical-session.target` (already correctly pulled in via
     `soundbooth.target`/`PartOf=`). That gave it an implicit
     `Before=graphical-session.target`, which combined with its own
     `After=ffmpeg-srt.service` and `ffmpeg-srt.service`'s own
     `After=graphical-session.target` formed a 3-way cycle
     (`ffmpeg-srt.service` → `graphical-session.target` →
     `ffmpeg-srt-watch.service` → `ffmpeg-srt.service`). systemd silently
     deleted `ffmpeg-srt.service`'s start job every boot to break it — it
     never started. Fixed by removing the redundant `WantedBy=` line
     (`audio-routing/systemd/ffmpeg-srt-watch.service`) + removing the stale
     `graphical-session.target.wants/` symlink + `daemon-reload`.
  2. **PipeWire claimed the ATEM's own audio capture device**
     (`/dev/snd/pcmC1D0c`), so ffmpeg's direct ALSA open
     (`plughw:Extreme,0`) failed with "Device or resource busy" every
     restart. Architecture requires ffmpeg to have this device exclusively
     (Pulse capture is unreliable with FFmpeg for it) — nothing legitimately
     needs it inside PipeWire, unlike the PreSonus card. Fixed with a new
     rule `audio-routing/wireplumber/52-atem-audio-ignore.lua`
     (`device.disabled=true` matched on
     `alsa_card.usb-Blackmagic_Design_ATEM_Mini_Extreme*`), installed to
     `~/.config/wireplumber/main.lua.d/`.
  - Note: initially suspected USB bandwidth contention with the PreSonus
    bridge (both devices share USB Bus 003, confirmed via `lsusb -t`) because
    stopping the bridge coincided with video capture starting to succeed —
    but after fixing bug #2, bridge + ffmpeg-srt run fine simultaneously, so
    that was most likely a timing coincidence during retries, not a real
    bandwidth ceiling. Worth keeping in mind if ENOSPC-style errors resurface
    under heavier simultaneous load, but not treated as confirmed today.
  - Verified: `ffmpeg-srt.service` active and encoding (audio+video streams
    opened, CPU ~110%), `presonus-foh-bridge.service` active concurrently,
    health 0 fail.

## Current State (2026-08-02 evening — FOH root-cause session)

**Read this before touching FOH audio again.** Corrects the "PreSonus full PW
restored... bridge stopped/disabled" line further down — that never actually
held; live system was on the bridge again by this afternoon.

- [x] **Root-caused and FIXED: WirePlumber volume-restore bug.**
  `~/.local/state/wireplumber/restore-stream` had stale **32-element**
  `channelVolumes`/`channelMap` entries for the PreSonus playback nodes
  (`...multichannel-output`, `...pro-output-0`), while the live node is
  **64-channel**. WirePlumber's stock `restore-stream.lua` replays whatever
  length array it last saved onto the node with **zero validation** — that
  mismatch is what caused "volume stuck at 0%/-inf" on the native PW path.
  Likely source of the truncation: `ensure-audio-routes.sh`'s
  `presonus_force_unity_volume()` used to call `pactl set-sink-mute`/
  `set-sink-volume` (libpulse, hard-capped at 32 channels) right before its
  own correct 64-element `pw-cli` write — **removed those pactl calls**, kept
  only the `pw-cli set-param` path. Confirmed fix: after clearing the stale
  restore-stream lines + restarting wireplumber, AUX0/AUX1 read **100%/0.00dB**
  on both `output:multichannel-output` and canonical `pro-audio` profiles.
- [ ] **Found but NOT fixed: native PW playback path still produces no audible
  signal at the board**, despite volume now correct and Mixer→AUX0/1 linked.
  ALSA-level check (`/proc/asound/cardN/pcm0p/sub0/status`) showed the
  playback PCM enters **XRUN immediately on open and never recovers**
  (`hw_ptr` frozen ~1 period in) — a second, separate, deeper bug from the
  volume issue. Native path is NOT ready to be made canonical yet.
- [x] **Swept all 64 USB playback channels** (0–63, one test tone at a time,
  via `aplay -D presonus_foh_raw -t raw -f S32_LE -r 48000 -c 64`) with the
  ALSA bridge stopped so the raw device was free. Confirmed via
  `/proc/asound/card3/pcm0p/sub0/status` that the computer genuinely
  transmits PCM data over USB with no XRUN (`state: RUNNING`, `hw_ptr`
  advancing) when using the bridge's normal 2ch path — but **the operator
  saw zero meter/channel activity on the board across all 64 channels**.
  Checked `StudioLive Internal Clock Validity` ALSA control — reports `on`
  (clock is locked, not the cause).
- [ ] **This points to a board-side issue, not a computer software bug**:
  either the console needs "USB Return"/USB input explicitly selected or
  patched into a monitored bus (check the 32SX's own routing screen /
  UC Surface), or something else on the hardware side. Software-side data
  path (Spotify/tone → Mixer → parec → aplay → USB channels 0/1) is fully
  verified healthy — this is no longer a PipeWire/ALSA config problem to
  chase further from the computer alone.
- [x] **Bridge crash-loop found + fixed mid-session:** restarting WirePlumber
  during testing left `presonus-foh-bridge.service` crash-looping every ~30s
  (`parec: Stream error: Timeout`) regardless of whether audio was playing.
  Fixed by `systemctl --user restart pipewire pipewire-pulse wireplumber`
  (full stack, not just wireplumber) + re-running `ensure-audio-routes.sh`.
  Bridge ran stable 2.5+ min afterward with `NRestarts=0`.
- [x] Operator power-cycled the physical board; computer rebooted right after
  (this session) for a fully clean state on both sides before continuing.
- **Next when resuming:** run `~/bin/soundbooth-health.sh` first (expect
  **foh-graph PASS** via bridge, bridge stable). Then check the board's own
  routing for USB Return 1/2 (or whichever bus/channel strip is meant to
  monitor it) — this is the open thread. Do NOT switch the PreSonus card
  profile to `pro-audio`/`output:multichannel-output` for production use
  until the ALSA XRUN (native path) is separately root-caused — bridge stays
  default. Plan file (if still present):
  `~/.claude/plans/pure-crafting-beacon.md`.

## Current State (2026-08-02 later)
- [x] **PreSonus full PW restored (2026-08-02 afternoon):** removed `device.disabled`; soft-mixer only. pro-audio 64ch in/out back for Ardour/qpwgraph. ALSA FOH bridge stopped/disabled (was exclusive). Mixer→AUX0/1 linked. Playback volume-at-0 FOH bug still under investigation.
- [x] **Livestream mid-stream drop:** SRT tee slave failed I/O ~35 min into session; local UDP OK; no reconnect with `onfail=ignore`
- [x] **`ffmpeg-srt-watch.service`:** journal watch → restart encode+display on `Slave muxer #N failed` (backup)
- [x] **SRT `onfail=abort`** (default): mid-stream SRT death exits ffmpeg → systemd `Restart=always` + `ExecStartPost` restarts `ffmpeg-display`. Override: `FFMPEG_SRT_ONFAIL=ignore` in conf

## Current State (2026-08-02)
- [x] **FreeShow → FOH silent root cause:** FreeShow was already on **PipeWire** (`pipewire-pulse`, app name Chromium) → Mixer @150%. Not ALSA.
- [x] **Real fault:** StudioLive USB is **64ch S32_LE only**. PipeWire sink channel volumes stick at **0%/-inf** → Mixer→board graph links carry silence. Health foh-graph could still PASS on links alone.
- [x] **Fix:** `presonus-foh-bridge.service` — `parec Mixer.monitor | aplay -D presonus_foh` (ALSA plug maps stereo→ch0/1). Enabled in `soundbooth.target`.
- [x] WP `51-presonus-soft-mixer.lua` disables stock PreSonus ACP nodes; `~/.asoundrc` pcm.presonus_foh
- [x] Health **foh-graph** checks bridge; ensure-audio-routes notes bridge


# Soundbooth Project — Cross-Session Status

Updated: 2026-07-30 (FFmpeg lip-sync delay restored to 0.25)

## Current State (2026-07-30)
- [x] **Livestream A/V sync A/B:** delay **0** → operator audio **leads ~0.25s**; restored **0.25** (raw path early audio). Persisted:
  - live `~/.config/soundbooth/ffmpeg-srt.conf` → `FFMPEG_AUDIO_DELAY_SEC=0.25`
  - script default + example + SYSTEM-STATE; stack restarted
  - Note: earlier “lag at 0.25” may have been conf confusion or different reference; current A/B favors **0.25** for lead-at-zero
- [x] **Prior (2026-07-26):** same **0.25s** baseline; synthetic @0.25 measured **265 ms** (OK). Fine-tune with `/av-sync-calibrate` if needed.
- [x] **A/V sync automator** (`av-sync-calibrate.py` → `~/bin/av-sync-calibrate`):
  - synthetic + live capture-udp on tee **:5002**; write-cal / --apply-restart for ATEM-path recalibration
  - **Grok skill** (manual only): `.grok/skills/av-sync-calibrate/` → `/av-sync-calibrate`; **never auto-run**

## Priority Order
1. Audio routing (default all sources → Presonus; program audio → HDMI TV via FFmpeg/ffplay)
2. Replicability + soundbooth-project bootstrap + setup system foundation
3. Portal / wiki (local only) + docs

## Later / backlog

### Multiview: true ffplay / DP-4 ScreenCast (optional R&D)
- [ ] **Not for live service default.** Tiles 3+4 currently tee **encode** (`:5001`); tile 3 is *not* true DP-4 pixels.
- [ ] Revisit **ScreenCast of real ffplay output** so operators can see “what’s actually on sanctuary TV” (wrong window, black player, browser on DP-4).
- [ ] Prior attempts: `RecordMonitor DP-4` ~**0–2 fps** / freeze until workspace switch; FreeShow monitors OK ~20 fps with `is-recording=true`.
- [ ] Try next (off-service):
  1. `RecordWindow` of window title **Soundbooth Program** / ffplay (may work better than FreeShow Electron case)
  2. Flag `MULTIVIEW_PROGRAM_MODE=encode|screencast` (default **encode**)
  3. Rate log + **auto-fallback to encode** if program ScreenCast &lt; ~2 fps for N seconds
  4. Keep tile 4 as encode/SRT always; only tile 3 optional true DP-4
- [ ] Accept only if stable ≥ ~5–8 fps without workspace thrashing; otherwise leave encode tee.
- Context: Sunday 2026-07-19 session; SYSTEM-STATE multiview section.

## Current State (2026-07-19)

### Session GUI autostart (2026-07-19)
- [x] XDG autostart desktops: Spotify, FreeShow (`start-freeshow.sh`), Vivaldi browser, **multiview**
- [x] Source under `audio-routing/autostart/`; install via `~/bin/install-booth-autostart.sh`
- [x] Live: `~/.config/autostart/soundbooth-*.desktop` (delays 8–18s for PipeWire/displays/ffmpeg)
- [x] Health: `soundbooth-health.sh` auto-discovers Mutter Xwayland cookie (no false display FAIL)
- [x] Multiview not running → health **FAIL** (was false PASS “optional”); root cause: never in autostart

### Booth multiview (2026-07-19)
- [x] x11grab black under Wayland; RecordWindow grabbed **wrong surface** (Grok terminal)
- [x] Fixed: **one Mutter ScreenCast session per monitor** (RecordMonitor DP-2/3/4) + encode :5001  
  Multi-stream single session left DP-2/DP-3 black
- [x] Live verify: Primary/Stage tiles show FreeShow slides; Program/encode non-black
- [x] Health: `check_multiview` (connectors, :5001, process/window when running)
- [x] Multiview → **workspace 2**: Wayland needs Mutter API; patched Auto Move Windows (title/GStreamer match)
- [x] Browser: `start-booth-browser.sh` forces Vivaldi onto **DP-1** (not program DP-4)
- [ ] After GNOME extension updates: re-run `~/bin/configure-multiview-workspace.sh` if multiview sticks to ws1
- [x] Encode tile black: feeder used `-fflags nobuffer` mid-stream → no H.264 SPS/PPS lock; fixed with probesize/analyzeduration + restart loop
- [x] **Encode tile still black (Sunday 2026-07-19):** feeder decoded fine (~8 fps, non-zero luma) but appsrc used **synthetic pts=0…n** while ScreenCast pads use live clock → compositor dropped sink_3 as late. Fix: stamp buffers with pipeline running time; `sink_3::max-lateness=-1`; stderr to file (not PIPE); UDP `timeout=0`. Installed `~/bin/booth-multiview.py`; multiview restarted (SRT untouched). Verified `frames=480 push=OK sample_avg≈98`.
- [x] **Program tile frozen until workspace switch (Sunday 2026-07-19):** encode tile updated on camera move; DP-4 ScreenCast stayed stale. Measured FreeShow ScreenCast ~20 fps but **program ~0–2 fps** (Mutter damage path + ffplay/Xwayland). Fix: stop RecordMonitor of DP-4; **tee encode into tiles 3+4**; FreeShow only ScreenCast with `is-recording=true` + `target-object=serial` + always-copy + PTS probes. Labels: “3 Program (encode live)” / “4 FFmpeg encode / SRT”.
- [ ] **Later:** optional true DP-4/ffplay ScreenCast (see **Later / backlog** above) — encode tee remains default
- [x] Health expanded: multiview feeder flags, workspace patch, session autostart, browser DP-1
- [x] Tests: `tests/manual-test.md` rewritten; `tests/smoke-health.sh`; `tests/multiview-checklist.md`

### Cleanup / optimization (2026-07-19 afternoon)
- [x] **Health:** `foh-graph` FAIL if Mixer→Presonus AUX0/1 missing; no VLC services PASS; Ardour inactive no longer WARNs
- [x] **Boot:** `ensure-audio-routes.service` oneshot after qpwgraph (WantedBy `soundbooth.target`)
- [x] **VLC services removed** completely (`vlc.service`, `vlc-display-guard` units + live files); optional manual `start-vlc.sh` remains for future media-player use only
- [x] **Ardour off by default** (not WantedBy default; start manually when recording)
- [x] Patchbay slimmed (no VLC edges); project copy under `audio-routing/patchbay/`
- [x] `virtual-audio.service` fixed (was setting removed **System** sink → fail); now Mixer
- [x] Portal/REBUILD/SYSTEM-STATE/AGENTS updated; Subsplash verify URL in health hints
- Health after cleanup: **37 pass / 0 warn / 0 fail**

### Sunday service boot (2026-07-19)
- [x] **Root cause:** `soundbooth.target` still `Wants=vlc.service` → VLC owned `/dev/video0` → `ffmpeg-srt` crash-looped
- [x] Stopped VLC; started `ffmpeg-srt` + `ffmpeg-display` + guard
- [x] Fixed live unit: `~/.config/systemd/user/soundbooth.target` now Wants FFmpeg stack (not VLC)
- [x] Camera health IP corrected: **192.168.1.202** (was wrong default 192.168.2.202); ping OK
- [x] **Post-reboot races fixed:**
  - Sunday Grok skipped: **calendar-day stamp** from earlier session → now **once per `boot_id`**
  - Grok waits for **network/DNS** (default 180s) + settle, then opens terminal for diagnostics
  - Livestream: SRT tee open failed with `Name or service not known` when WAN/DNS late; local UDP survived (`onfail=ignore`) but SRT never retried → `start-ffmpeg-srt.sh` now waits for SRT hostname DNS (default 120s) + openable video0
  - Guard: removed `BindsTo=ffmpeg-srt` (first srt crash permanently stopped guard)
- [x] **FOH silent while Spotify “on Mixer”:** `spotify→Mixer` linked but **Mixer→Presonus AUX0/1 missing**. Fixed live + now covered by health **foh-graph** + boot oneshot.

## Current State (2026-07-12)

### audio-routing/
- [x] WirePlumber Lua rule installed (`~/.config/wireplumber/main.lua.d/50-soundbooth-software-to-mixer.lua`)
- [x] `ensure-audio-routes.sh`, `start-qpwgraph.sh` in `~/bin` + project
- [x] Live verify: Spotify / FreeShow route to Presonus after reboot/restart
- [x] qpwgraph start crash mitigated (wrapper); restart clean
- [x] **Spotify intermittent silence (2026-07-12):** qpwgraph **exclusive** (`-x`) + stale patchbay (`Mxier`/`vMixer`) disconnected Spotify after brief audio. Fixed: patchbay rewritten (Mixer→Presonus, Spotify→Mixer, ATEM→VLC); start with `-a` only; ensure-audio-routes finds Spotify.
- [x] FreeShow webm stutter root cause: WX 3200 has no VP9 HW decode (VAAPI H.264/HEVC only)
- [x] Converted Downloads webms → H.264/AAC MP4:
  - `Downloads/Skit Guys - Being Mom [H-Kw6cOwh2c].mp4` (h264 854x480)
  - `Downloads/yt-dlp_linux (2)/Girls Captain…2026….mp4` (h264 3840x2160)
- [x] Batch converter: `~/bin/convert-for-freeshow-batch.sh`
- [x] FreeShow-friendly downloader: `~/bin/yt-dlp-freeshow.sh`
- [x] **Diagnostics toolkit:** `audio-routing/scripts/soundbooth-health.sh` → `~/bin/soundbooth-health.sh`
  - Checks: USB, ATEM/camera net, `/dev/video0`, FFmpeg SRT + ffplay DP-4, **program-audio** (ALSA xrun/underrun journal, AAC path, ffplay≠Mixer), Mixer policy, services
  - Exit: 0=ok, 1=warn, 2=fail; also `--quiet` / `--json`
- [x] **Default sink → Mixer** (live `wpctl`/`pactl` + WP `default-nodes` state; `ensure-audio-routes.sh` re-applies; Mixer `priority.session=2000` in pipewire-pulse virtual-controllers)
- [x] **VLC pipeline lightened:** display path no longer re-encodes; HTTP `:8081` is separate x264 ultrafast/zerolatency branch (`start-vlc.sh`)
  - Before: ~327% CPU, thousands of late-frame msgs/hour  
  - After: ~140% CPU, **0** late-frame msgs since restart; stream still produces TS
- [x] **VLC A/V sync tuning (2026-07-12):** ATEM video=v4l2 + audio=Pulse input-slave (no shared clock). Auto-detect full Pulse source; `--audio-desync` + live-caching via conf; HTTP audio 48 kHz; `clock-synchro=0`. Calibrated **+2000 ms** via A/V Sync Test — **confirmed correct** by operator.
- [x] **Sunday auto-Grok:** `sunday-grok.service` + `~/bin/sunday-grok-session.sh` — on **Sunday** graphical session, open Grok TUI (health-ready prompt) after settle delay. Conf: `~/.config/soundbooth/sunday-grok.conf`. Enabled for next Sunday boot.
- [ ] Optional: further cut VLC CPU (disable HTTP when unused, lower bitrate, or real HW encode if VLC gains h264_vaapi)
- [x] **Virtual sink cleanup (2026-07-12):** removed unused **System** null sink; fixed Mixer description typo (Mxier→Mixer); tidy patchbay backups; keep Mixer + LocalLive only.
- [x] **FreeShow / Spotify levels (2026-07-12):** FreeShow `settings.json` **volume 0.1→1.0** (root cause of quiet media); PipeWire FreeShow **150%**, Spotify **50%** via `ensure-audio-routes.sh`.
- [x] **FFmpeg SRT + DP-4 display (2026-07-12):** `ffmpeg-srt` = ATEM → SRT + UDP `:5000`; `ffmpeg-display` = **ffplay** fullscreen on DP-4. VLC **disabled**.
- [x] **ffplay restart loop fixed (2026-07-12):** guard used `xlsclients|grep ffplay` (always false on Wayland) → restart every 20s + `-alwaysontop` stole focus. Guard now only checks `pgrep -x ffplay` + debounce; removed alwaysontop.
- [x] **ffplay audio → HDMI TV (2026-07-12):** was forced to Mixer via `*player*` WP rule + pro-audio sinks. Now HDMI card `hdmi-stereo-extra1` (HDMI TV); ffplay `PULSE_SINK` + ensure-routes; ATEM audio via **ALSA hw:Extreme,0**.
- [x] **program-audio diagnostic (2026-07-19):** `soundbooth-health.sh` section **program-audio** — ATEM ALSA in cmdline, AAC encode, aresample, journal **ALSA xrun/underrun** (root cause of intermittent SRT/TV audio), ffplay not on Mixer.
- [ ] Confirm Subsplash accepts SRT streamid (resolve 401 if seen); tune bitrate/A-V delay if needed
- [ ] Optional: FreeShow audio device selection audit vs Mixer virtual

### replicability/
- [x] Project scaffold + provision (install.sh, package lists, REBUILD.md)
- [x] `backup-configs.sh` / `restore-configs.sh` (+ `~/bin/soundbooth-*-configs.sh`)
- [x] First config backup written under `replicability/backups/`
- [x] Git init + initial commit of `soundbooth-project/` (local identity)
- [ ] Practice restore dry-run on spare/VM when convenient
- [ ] webui/ollama cleanup when ready

### portal/
- [x] Skeleton + quick-reference (audio policy, FreeShow webm/mp4, backup cmds)
- [ ] More content from `booth_ai/booth-context.md` (startup checklists, diagrams)
- [ ] Desktop launcher polish / local serve on high port if desired

## How to pick up next session
```bash
cd ~/soundbooth-project
# 1) Architecture + policies (shared by ALL session types)
cat SYSTEM-STATE.md
# 2) Progress
cat STATUS.md
# See docs/MULTI-SESSION.md for diagnostics / troubleshooting / feature intents
# Backup: ~/bin/soundbooth-backup-configs.sh
```

## Display / VLC robustness (2026-07-12)
- [x] Diagnosed VLC on wrong output after HDMI hotplug (hard-coded `--qt-fullscreen-screennumber=3`)
- [x] `start-vlc.sh` resolves target by connector **DP-4** (config: `~/.config/soundbooth/vlc-display.conf`)
- [x] `vlc-display-guard.service` enabled — restarts VLC if window leaves DP-4
- [x] Shared helpers: `~/bin/vlc-display-lib.sh`
- [x] **Post-reboot race fixed:** cold boot had no `XAUTHORITY` → empty xrandr → fallback screen 1 (desktop); guard also blind. Now: discover Mutter Xwayland auth, wait for DP-4, fail/retry (no wrong-screen fallback); guard re-exports auth each loop + qt-screen desync check. Units WantedBy=`graphical-session.target`.
- [x] **XAUTHORITY subshell regression fixed (2026-07-12):** wait used `MON=$(soundbooth_wait_for_vlc_display)` → cookie exported only in subshell → parent launched VLC with `XAUTHORITY=unset` (desktop / no proper window; HTTP still encoded). Now `soundbooth_wait_for_vlc_display_into MON` + re-export before exec; guard restarts if active VLC has no window; `StartLimit*` moved to `[Unit]`. Live verify: window `+0+1080` on DP-4, health **PASS** VLC geometry.
- [x] **Post-boot verify (2026-07-12 ~15:53):** Display ready 1s with XAUTHORITY set; journal shows cookie at exec; window `0 1080` on DP-4; health **24 pass / 2 warn / 0 fail**.
- See `docs/display-investigation-2026-07-12.md` and portal quick-reference

## Diagnostics findings (2026-07-12 — post-boot)

| Area | Result | Detail |
|------|--------|--------|
| Hardware / ATEM / 4 displays | OK | Presonus + ATEM USB; video0; DP-1..4 |
| VLC placement | **OK** | qt-screen=3 = DP-4; window on DP-4; XAUTHORITY set at start |
| Default sink | **OK** | Mixer |
| VLC performance | expected | ~**137%** CPU (HTTP x264); **0** late frames this process |
| Remaining warns | optional | ardour inactive; VLC CPU elevated (encode branch) |

## Next Recommended
1. In FreeShow, swap playlists to the new `.mp4` files and confirm no stutter
2. Expand portal volunteer checklists from booth-context.md
3. Optional: further VLC HTTP cost reduction; remove unused open-webui/ollama

## Notes
- Policy: all software audio → Presonus StudioLive 32SX; VLC → HDMI TVs.
- Hardware: Ryzen 5 3600X, AMD Radeon PRO WX 3200, PreSonus StudioLive 32SX.
- Health: `~/bin/soundbooth-health.sh`
- Recovered prior session ID: `019f3379-9910-7140-a338-5548dbed8fc1` (see docs/SESSION-RECOVERY.md).
