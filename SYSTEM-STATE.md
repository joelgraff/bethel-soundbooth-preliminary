# Soundbooth System State (canonical)

**Living document.** Update this when hardware, routing, displays, or services change.  
All Grok sessions should treat this as the source of truth for “how the system works now.”

Last updated: 2026-09-01

---

## Mission

Ubuntu Linux PC in the church soundbooth: presentation, capture, recording, and software audio to FOH. Must boot predictably, route audio correctly, and be operable by volunteers.

---

## Hardware (summary)

| Item | Detail |
|------|--------|
| PC | ASRock B450M Pro4, Ryzen 5 3600X, ~40 GB RAM |
| GPU | AMD Radeon PRO WX 3200 (Polaris12) — **no VP9 HW decode**; H.264/HEVC VAAPI OK |
| Mixer | PreSonus StudioLive 32SX (USB) — power on before/with boot |
| Capture | Blackmagic **ATEM Mini Extreme** (UVC → `/dev/video0`, Pulse audio slave; Ethernet control **192.168.2.252**) |
| Network camera (health) | PTZOptics **PT12X-SDI-xx-G2** **192.168.1.202** (LAN `.1.x`; booth PC is `.2.10` via `192.168.2.1`. Not on ATEM subnet.) |
| Stagebox / monitors | NSB 16.8 (2), Earmix 16M (7), etc. (see `~/booth_ai/booth-context.md`) |
| Sanctuary displays | 85" Sony Bravia (2) + stage TV + outside monitors |
| HDMI extension | **GoFanco 1080p HDMI-over-Cat** multi-port + single stage TX (2020). Longest run ~**200 ft**. Plan: HDBaseT (e.g. Monoprice Blackbird) on locked Cat; fiber where new cable can be pulled. |

### GPU outputs (typical 4-head map)

| Connector | Identity | Typical role |
|-----------|----------|--------------|
| DP-1 | SAM S34CG50 ultrawide | Primary booth monitor |
| DP-2 | HXA **BMD HDMI** | FreeShow **Primary** |
| DP-3 | LKV/HDbitT-style / stage path | FreeShow **Stage** (GoFanco/extender) |
| DP-4 | SII **HDMI TV** | **ffplay** ATEM program to sanctuary TV |

Layout also stored in `~/.config/monitors.xml`. After hotplug, **connectors** are more stable than Qt “screen numbers.”

---

## Audio policy

1. **Default:** any software source (Spotify, browsers, FreeShow audio, etc.) → **Presonus 32SX** (via **Mixer** virtual sink / WirePlumber → **AUX0/1**).
2. **Exception:** **program path** (FFmpeg/ffplay) → AMD HDMI for sanctuary TVs (not forced to Mixer).
3. Virtual sinks (PipeWire null sinks):
   - **Mixer** — software apps → Presonus FOH (session default, elevated priority)
   - **LocalLive** — optional TV/program bus (legacy name; live program audio is ffplay → HDMI)
   - ~~**System**~~ — removed 2026-07-12 (unused)

### Key audio files / services

- WirePlumber rule: `~/.config/wireplumber/main.lua.d/50-soundbooth-software-to-mixer.lua`  
  (source copy: `soundbooth-project/audio-routing/wireplumber/`)
- Virtual sinks: `~/.config/pipewire/pipewire-pulse.conf.d/virtual-controllers.conf`  
  (source: `soundbooth-project/audio-routing/pipewire-pulse/`) — **Mixer** has elevated `priority.session`
- Session default sink: **Mixer** (WirePlumber `default-nodes` state; re-applied by `ensure-audio-routes.sh` / `virtual-audio.service`)
- Repair script: `~/bin/ensure-audio-routes.sh` (default sink + app→Mixer + Mixer→PreSonus AUX0/1 + soft volume attempt)
- **PreSonus in PipeWire (canonical):** full **pro-audio** I/O (**64ch** playback + capture) for **Ardour** and **qpwgraph**. Never `device.disabled` on the card.
- **WP:** `51-presonus-soft-mixer.lua` → soft-mixer + ignore-dB only. Profile **pro-audio** (default-profile).
- **FOH software (live default, 2026-08-02):** apps → **Mixer** → `presonus-foh-bridge.service` (ALSA `parec Mixer.monitor | aplay -D presonus_foh`, card profile `input:multichannel-input`) → USB return 1–2. This is the **actual production path today**, not the native PW `pro-output-0:playback_AUX0/1` link — see below.
- **Two FOH bugs found 2026-08-02** (see STATUS.md for full detail):
  1. **Volume-stuck-at-0% — ROOT-CAUSED + FIXED.** WirePlumber's `restore-stream.lua` replays a persisted `channelVolumes` array onto a node with **zero length validation**; a stale **32-element** array (likely truncated by a `pactl set-sink-volume` call hitting libpulse's 32-channel protocol cap) was being reapplied to the **64-channel** PreSonus node, corrupting AUX0/1's volume. Fixed by clearing the stale entries in `~/.local/state/wireplumber/restore-stream` + restarting wireplumber; confirmed AUX0/AUX1 read unity (100%/0.00dB) afterward. `ensure-audio-routes.sh`'s `presonus_force_unity_volume()` no longer calls `pactl set-sink-mute`/`set-sink-volume` (removed the corrupting calls; only the correct 64-element `pw-cli` write remains).
  2. **Native PW playback ALSA XRUN — CONFIRMED, NOT YET FIXED.** Even with volume correct, opening the native `pro-output-0`/`multichannel-output` PW sink puts the underlying ALSA PCM into XRUN immediately (`hw_ptr` frozen ~1 period in, `/proc/asound/cardN/pcm0p/sub0/status`) and it never recovers — silent regardless of volume. **Do not switch the PreSonus card profile to `pro-audio`/`output:multichannel-output` for production** until this is separately root-caused (suspect USB isochronous bandwidth/timing for 64ch/32-bit/48kHz, possibly contending with ATEM capture on the same controller). The ALSA bridge remains the default FOH path for this reason.
- **Board preamp/gain trim does nothing for this channel** — USB return channels are digital, not routed through the analog preamp stage, so the physical gain knob has no effect (confirmed, not a bug). **Use the board's channel fader** to adjust level instead.
- **Software gain levels (re-tuned by ear 2026-08-02, post-fix):** `ensure-audio-routes.sh` sets both Spotify and FreeShow PipeWire stream volume to **33%** (`SOFTWARE_VOLUME_PCT`/`FREESHOW_VOLUME_PCT`). The old 150%/50% defaults were tuned to compensate for the broken/attenuated signal above and now clip hard since AUX0/1 pass at clean unity gain. FreeShow's own in-app volume (`~/.config/freeshow/settings.json` → `"volume"`) stays at **1.0** — the 33% adjustment is the PipeWire stream level on top of that. Re-tune by ear with `pavucontrol` if sources or mastering loudness change; Spotify's slider there matches its PipeWire volume directly.
- Boot oneshot: `ensure-audio-routes.service` after qpwgraph
- Patchbay: `~/patchbay_profile/soundbooth.qpwgraph` + `qpwgraph.service` (wrapper `~/bin/start-qpwgraph.sh`)  
  Source: `soundbooth-project/audio-routing/patchbay/soundbooth.qpwgraph`
  - qpwgraph uses **activate only** (`-a`), **not exclusive** (`-x`). Exclusive mode tore down dynamic app links (Spotify cut in/out).
  - Patchbay: **Mixer→Presonus AUX0/1** (required FOH), Spotify→Mixer (aid). No VLC edges.
- User services (via `soundbooth.target`): `qpwgraph`, `ensure-audio-routes`, FFmpeg stack, virtual sinks default. **Ardour off by default** (`systemctl --user start ardour` when needed). **No VLC units.**
- **Session GUI apps (XDG autostart):** Spotify, FreeShow, web browser (Vivaldi), and the **control dashboard** via `~/.config/autostart/soundbooth-*.desktop`.  
  - Source: `soundbooth-project/audio-routing/autostart/`  
  - Install/refresh: `~/bin/install-booth-autostart.sh` (remove: `--remove`)  
  - FreeShow launcher: `~/bin/start-freeshow.sh` (VAAPI Electron hints) — force-places the **main** FreeShow window onto **DP-1** on launch (same dead-zone/remote-TV fix as the browser, below); Primary/Stage output windows are untouched  
  - Browser: **Vivaldi** via `~/bin/start-booth-browser.sh` — forced onto **DP-1** (booth), not program DP-4  
  - Dashboard: `~/bin/start-booth-dashboard-view.sh` (Vivaldi `--app=` mode, own profile); lands on **workspace 2** — see "Control dashboard (booth session)" below  
  - Not systemd: GUI apps inherit the full GNOME session (DISPLAY/Wayland/DBus); closing a window does **not** auto-restart
- **Sunday Grok:** `sunday-grok.service` (WantedBy=`graphical-session.target`) runs `~/bin/sunday-grok-session.sh` — **Sundays only**, opens interactive Grok in `gnome-terminal` **after network (DNS) + settle delay**, then health-ready prompt. Config: `~/.config/soundbooth/sunday-grok.conf` (`NET_WAIT`, `DELAY`). Stamp is **once per boot** (`boot_id`), not once per calendar day (so reboot re-launches). Disable: `SOUNDBOOTH_SUNDAY_GROK=0` or `systemctl --user disable sunday-grok.service`. Test any day: `SOUNDBOOTH_SUNDAY_GROK_FORCE=1 ~/bin/sunday-grok-session.sh`.

---

## Video / program display / FreeShow

### Program video + livestream (FFmpeg only — no VLC services)

**ATEM UVC allows only one opener** of `/dev/video0`. Architecture
(2026-07-12; **livestream leg split from capture 2026-08-23** so the stream
to Subsplash can be ended on purpose — end of service — without touching
capture or the sanctuary TV):

```
ATEM video0 + Pulse audio
        ↓
  ffmpeg-capture.service  (owns capture, always-on)
        ├─→ UDP MPEG-TS 127.0.0.1:5000 ──→ ffmpeg-display.service (ffplay) → DP-4 sanctuary TV
        ├─→ UDP MPEG-TS 127.0.0.1:5001 ──→ multiview tile (retired — tee left in place, currently unconsumed)
        ├─→ UDP MPEG-TS 127.0.0.1:5002 ──→ av-sync-calibrate probe (free tee)
        └─→ UDP MPEG-TS 127.0.0.1:5003 ──→ ffmpeg-srt-relay.service ──→ SRT caller → Subsplash
```

Each local port is **unicast** (one reader only) — each consumer gets its
own dedicated port rather than sharing one. `ffmpeg-srt-relay.service` is
the *only* process that talks to Subsplash; it stream-copies (no re-encode,
~2.6% CPU) rather than decoding+re-encoding a second time.

**End the livestream (e.g. end of service):** `~/bin/stop-live-stream.sh`
(stops just the relay — capture and the TV keep running). Resume:
`~/bin/start-live-stream.sh`. This is the fix for Subsplash otherwise
keeping a live event open for up to 8 hours if not explicitly ended.

#### FFmpeg capture (`ffmpeg-capture.service`)
- Start: `~/bin/start-ffmpeg-capture.sh`
- Config: `~/.config/soundbooth/ffmpeg-srt.conf` (**SRT URL / streamid — local only, not in git**; shared with the relay below)
  - Template: `soundbooth-project/audio-routing/ffmpeg-srt.conf.example`
  - Connector target still from `vlc-display.conf` → `VLC_OUTPUT_CONNECTOR=DP-4` (shared name)
- Encode: **libx264** veryfast/zerolatency; audio delay `FFMPEG_AUDIO_DELAY_SEC` via **`adelay`** (live conf **0.25** — raw ATEM path audio leads ~0.25s; A/B 2026-07-30: delay 0 → lead, delay 0.25 → match). Edit `~/.config/soundbooth/ffmpeg-srt.conf` then `systemctl --user restart ffmpeg-capture ffmpeg-display`
- Local UDP tees: **:5000** ffplay · **:5001** unconsumed since multiview retired 2026-09-01 · **:5002** free probe (`av-sync-calibrate capture-udp`) · **:5003** livestream relay input
- A/V calibrator (manual only, **not** boot/health): `~/bin/av-sync-calibrate` + Grok skill `/av-sync-calibrate`  
  (`.grok/skills/av-sync-calibrate/SKILL.md`; script `audio-routing/scripts/av-sync-calibrate.py`)
- **Boot races:** waits for openable `/dev/video0` (udev/ACL). No longer waits on SRT/DNS — that's the relay's problem now, so a slow/down network never delays the TV.
- All 4 local tee legs are `onfail=ignore` — none of them can take capture down, and (since 2026-08-23) neither can a Subsplash outage, because SRT delivery no longer lives in this process at all.
- `ExecStartPost` `try-restart` on both `ffmpeg-display.service` and `ffmpeg-srt-relay.service` so both reattach after a capture (re)start — no-ops for either if it wasn't already running (e.g. relay intentionally stopped between services).
- `SuccessExitStatus=255` set — ffmpeg's SIGTERM handler exits 255 even on a clean stop; without this a normal `systemctl stop`/restart shows as "failed".

#### Livestream relay (`ffmpeg-srt-relay.service`)
- Start: `~/bin/start-ffmpeg-srt-relay.sh` — reads capture's `:5003` tee, stream-copies to `FFMPEG_SRT_URL` (same conf file as capture)
- **This is the entire livestream leg.** Stopping it ends the Subsplash event immediately; capture and DP-4 display are untouched.
- **Boot races:** waits for openable capture service + **DNS of SRT host** (default up to 120s, `FFMPEG_SRT_DNS_WAIT_SEC`) — this used to block the whole encode+TV at boot; now it only delays the livestream leg.
- **SRT mid-stream fail / reconnect (2026-08-02 behavior, now isolated to this unit):** a dead SRT connection makes ffmpeg exit → `Restart=always` (8s) reconnects. A deliberate `systemctl --user stop` (i.e. `stop-live-stream.sh`) does **not** trigger a restart — that's the whole point.
- **Backup watch:** `ffmpeg-srt-watch.service` → journal SRT connection-drop patterns → restart the relay only (90s debounce, max 8/h) if the process hangs without exiting.
- `soundbooth-health.sh`: listed in `OPTIONAL_SERVICES` (like Ardour) — PASS when active, **silent (not a warning) when stopped**, since that's now an intentional, expected end-of-service state.
- `SuccessExitStatus=255` set (see capture, above) so `stop-live-stream.sh` reads as a clean "inactive", not "failed".
- **Not yet built:** tying `stop-live-stream.sh` to a physical ATEM Mini button press (deferred; command-line control shipped first).
- **Auto-end on camera power-off (`livestream-camera-watch.service`, 2026-08-23):**
  the PTZOptics camera at `CAMERA_NETWORK_IP` (default `192.168.1.202`) is the
  *same physical unit* whose SDI output feeds the ATEM's program input —
  confirmed operators power the camera off well before the booth PC/ATEM, so
  `/dev/video0` never disappears in the normal end-of-service sequence and
  can't be used as the "camera off" signal. Instead this watcher pings the
  camera every 15s (`LIVESTREAM_CAMERA_POLL_SEC`); after 60s
  (`LIVESTREAM_CAMERA_GRACE_SEC`) of sustained unreachability it runs
  `stop-live-stream.sh` automatically (once per outage — doesn't spam).
  Deliberately **one-directional**: never restarts the stream when the
  camera comes back — resuming is always `~/bin/start-live-stream.sh`.
  Script: `~/bin/livestream-camera-watch.sh`. Distinct from
  `camera-management-watch.service` (restarts the CMP preview app; unrelated
  purpose despite the similar name).

#### Program display (`ffmpeg-display.service`)
- Start: `~/bin/start-ffmpeg-display.sh` — **ffplay** fullscreen at DP-4 geometry
- Local feed: `udp://@127.0.0.1:5000` from ffmpeg-capture
- **Audio:** Pulse → `alsa_output…hdmi-stereo-extra1` (**HDMI TV** / DP-4), **not Mixer/FOH**
  - GPU card profile: `output:hdmi-stereo-extra1` (not pro-audio multi-PCM)
  - WirePlumber: ffplay → HDMI TV; software apps still → Mixer
- Window title: **Soundbooth Program** (no always-on-top)
- Guard: `ffmpeg-display-guard.service` only restarts if `ffplay` process dies (debounced). **Not** `BindsTo=ffmpeg-capture` (that killed the guard on first encode crash at boot)
- **VLC services removed** — do not reinstall `vlc.service` / `vlc-display-guard` (fights FFmpeg for `/dev/video0`). Optional manual VLC as a normal media player is OK.
- Aggregate target: `soundbooth.target` Wants FFmpeg stack + qpwgraph + **ensure-audio-routes** (+ virtual sinks). **Not** Ardour. **Not** VLC.
- Restart program (TV path only, does not touch livestream): `systemctl --user restart ffmpeg-capture.service ffmpeg-display.service`
- ATEM capture audio via **ALSA** `plughw:Extreme,0` (Pulse capture unreliable with FFmpeg). WirePlumber rule `52-atem-audio-ignore.lua` sets `device.disabled=true` on the ATEM's audio card so PipeWire never claims it — without this, PipeWire's ALSA monitor can grab the device on boot before ffmpeg-capture does, and ffmpeg's direct ALSA open then fails with "Device or resource busy" (root-caused 2026-08-02, unlike PreSonus this card has no legitimate PipeWire consumer so `device.disabled` is safe here).
- Encode: H.264 **main@L4.0**, repeat-headers, 2s keyframes — if Subsplash shows "stream but no video", re-arm event and restart `ffmpeg-srt-relay`
- **Livestream verify (browser):** https://dashboard.subsplash.com/-d/#/media/live

### PTZOptics (control / IP preview — not the program path)

Program video is **SDI → ATEM**, not this IP stream. CMP is PTZ + operator preview only.

- Camera: **PT12X-SDI-xx-G2** `192.168.1.202` (VISCA `:5678`, RTSP `:554`, HTTP `:80`). NDI is **off**.
- App: PTZOptics **CMP 1.9.7**, run **unpacked** from `~/AppImage/Camera-Management-Platform-1.9.7.extracted/` (user unit `camera-management.service`). Packed AppImage `import("get-port")` hits `app.asar` as a file (`ENOTDIR`) → RTSP-MPEG never starts (blank pane, no error GIF).
- Preview: `~/.cmp_config/app_settings.json` **`usePreview`: `rtsp stream - mpeg`**. ffmpeg transcodes `rtsp://192.168.1.202` → MPEG1, JSMpeg on `ws://localhost:9999`.
- **HTTP snapshot does not work:** `/snapshot.jpg` is HTTP 200 + **Content-Length 0**. Phone app uses RTSP, which is fine.
- HTTP Basic auth is **on** on the camera web UI. Firmware **SOC v6.2.82** (CMP lists **v6.3.62**) — do not flash mid-service.

### FreeShow

- Outputs in `~/.config/freeshow/settings.json`: **Primary** (BMD/DP-2), **Stage** (extender/DP-3)
- Prefer **MP4/H.264** media; webm/VP9 stutters on WX 3200
- Helpers: `~/bin/convert-for-freeshow.sh`, `convert-for-freeshow-batch.sh`, `yt-dlp-freeshow.sh`

### Control dashboard (booth session)

**Retired 2026-09-01: booth multiview** (`booth-multiview.py`, the 2×2
GStreamer preview grid on DP-1). Its whole job — let the operator glance at
FreeShow Primary/Stage + program without walking to the physical TVs — moved
into the web control dashboard's own HDMI preview tiles (`dashboard/`,
`audio-routing/scripts/hdmi-preview-capture.py` +
`start-hdmi-preview-dp4.sh`). `booth-multiview.py`/`start-booth-multiview.sh`
are still in the repo (not deleted, just not autostarted/health-checked) in
case they're ever wanted again — reinstate via
`audio-routing/scripts/install-booth-autostart.sh`'s old `FILES` entry and
`soundbooth-health.sh`'s git history if so.

- **Expected on session** (Sunday ops): XDG autostart `soundbooth-dashboard.desktop` → `~/bin/start-booth-dashboard-view.sh` (Vivaldi `--app=http://127.0.0.1:8420/`, own profile `~/.config/vivaldi-dashboard`)
- Manual start: `~/bin/start-booth-dashboard-view.sh`
- **GNOME workspace 2**, same Wayland-native mechanism multiview used (X11 `wmctrl`/xprop **cannot** move Mutter workspaces on Wayland):
  - Primary: `soundbooth-multiview-workspace@soundbooth` Shell extension — title-matches the dashboard's page title **"Soundbooth Control"** (Vivaldi `--app=` mode titles the window after `<title>`), moves it via `MetaWindow.change_workspace_by_index`. Repurposed in place from the old multiview extension (same UUID, new target). **Extension code changes need a fresh GNOME Shell start to take effect** — `gnome-extensions disable/enable` and the `org.gnome.Shell.Extensions` D-Bus `EnableExtension`/`DisableExtension` calls report success but do **not** reliably reload already-loaded JS in this GNOME 46 session (confirmed 2026-09-01: `ReloadExtension` isn't even implemented despite being advertised); metadata (`name`/`description`) visibly stays stale too. Takes effect on next login/reboot.
  - Backup: **Auto Move Windows**, `application-list` → `soundbooth-dashboard.desktop:2`, matched via `--class=SoundboothDashboard` (Vivaldi's `--class` flag sets the Wayland `app_id`) + `StartupWMClass=SoundboothDashboard`. This one **is** gsettings-data-driven (no code to reload), so it's the one actually doing the work on an already-running session.
  - Switch: **Super+Page_Down** or **Super+Alt+2**. Re-apply after GNOME updates: `~/bin/configure-dashboard-workspace.sh`
- Health: no longer a `soundbooth-health.sh` check (was `check_multiview`, removed) — the dashboard has its own systemd units (`soundbooth-dashboard.service`, `hdmi-preview.service`, `hdmi-preview-dp4.service`) instead.

---

## Project tree (all durable work)

```
~/soundbooth-project/     # git repo — setup system + docs
  SYSTEM-STATE.md         # THIS file (canonical)
  STATUS.md               # task progress across sessions
  AGENTS.md               # project rules for Grok
  audio-routing/
  replicability/
  portal/
  docs/
~/bin/                    # live scripts used by services
~/booth_ai/booth-context.md  # older hardware notes (supplement)
```

Config backup: `~/bin/soundbooth-backup-configs.sh`

---

## Session types (use these intents; shared state is always this file)

| Session focus | Goal | Still must honor |
|---------------|------|------------------|
| **Diagnostics toolkit** | Build checks/scripts for audio, displays, ATEM, services | SYSTEM-STATE policies |
| **Troubleshooting** | Fix a live fault | Read SYSTEM-STATE + STATUS first |
| **Feature / build** | New capability under soundbooth-project | Put artifacts in project tree; update STATUS |
| **Portal / docs** | Volunteer-facing knowledge | Align with SYSTEM-STATE |

---

## Ops habits

1. Presonus on before/with PC boot.  
2. After HDMI extender glitches: check Displays; `systemctl --user restart ffmpeg-display.service`; FreeShow may need output re-check.  
3. After ATEM USB power cycles: wait for `/dev/video0`, then restart `ffmpeg-capture` + `ffmpeg-display`.  
4. FOH silent but apps show on Mixer: `systemctl --user restart presonus-foh-bridge ensure-audio-routes` (health **foh-graph**).  
5. End productive sessions: update **STATUS.md** + this file if architecture changed; optional `/flush` if memory enabled.

---

## Diagnostics

```bash
~/bin/soundbooth-health.sh          # full report (exit 0/1/2 = ok/warn/fail)
# source: soundbooth-project/audio-routing/scripts/soundbooth-health.sh
```

Covers USB (Presonus/ATEM), ATEM/camera network pings, capture node, FFmpeg SRT + ffplay on DP-4, **foh-graph** (Mixer→Presonus AUX0/1), **program-audio** (ATEM ALSA, AAC, aresample, journal xrun/underrun, ffplay≠Mixer), no VLC services, Mixer policy, services.  
Livestream: https://dashboard.subsplash.com/-d/#/media/live

---

## Known limitations / tech debt

- GoFanco HDMI-over-Cat is a reliability weak point (~200 ft longest); upgrade plan = HDBaseT (e.g. Blackbird) on existing Cat, fiber where pullable.
- VLC historically broke when using fixed `--qt-fullscreen-screennumber=3` after hotplug (fixed via connector resolve + guard).
- VLC HTTP branch still **software-encodes H.264** (`x264` ultrafast) for `:8081` (~1–1.5 cores). Display path no longer re-encodes. This VLC build has VAAPI decode/filters but **no h264_vaapi encoder** module.
- Default sink is **Mixer**; if a reboot reverts to motherboard analog, run `~/bin/ensure-audio-routes.sh` or `pactl set-default-sink Mixer`.
- VP9/webm not HW-accelerated on this GPU.
- open-webui/ollama test install may still exist; unused — removable in provision work.
