# Audio Routing

Goal: Every app that produces audio (Spotify, browsers, FreeShow, etc.) is automatically sent to the Presonus 32SX board.

**Hard rule**: Default route = Presonus mixer (via **Mixer** virtual sink).  
**Program exception**: FFmpeg/ffplay program audio → HDMI TV (DP-4), not Mixer/FOH.  
**Manual VLC**: may be used as a normal media player; **no VLC systemd services**.

## Install / verify

```
./scripts/install-soundbooth-system.sh          # scripts -> ~/bin, units -> systemd, enable
./scripts/install-soundbooth-system.sh --check  # read-only drift report (exit 1 if drift)
```

This is the supported way to get this repo onto the booth PC — see
`replicability/REBUILD.md`. `--check` is safe against a running booth and is the quickest
way to confirm the live machine still matches git. It never starts or stops anything.

## Contents
- `scripts/install-soundbooth-system.sh` — installs scripts + units and enables the right set; `--check` verifies without changing anything.
- `wireplumber/` — Lua policy scripts for auto linking (WirePlumber 0.4 style).
- `pipewire-pulse/virtual-controllers.conf` — **Mixer** + **LocalLive** null sinks.
- `scripts/ensure-audio-routes.sh` — Repair default sink, app→Mixer, **Mixer→Presonus AUX0/1**.
- `scripts/start-ffmpeg-capture.sh` — ATEM capture → local UDP TS tees (display, multiview, probe, livestream relay). Always-on; does not talk to Subsplash directly.
- `scripts/start-ffmpeg-srt-relay.sh` — reads capture's dedicated tee → SRT livestream (Subsplash). The only process that talks to Subsplash; can be stopped/started independently of capture/display.
- `scripts/stop-live-stream.sh` / `scripts/start-live-stream.sh` — end/resume the Subsplash livestream now (e.g. at end of service) without touching capture or the sanctuary TV.
- `scripts/livestream-camera-watch.sh` — auto-ends the livestream if the program camera goes unreachable on the network for 60s (safe proxy for "camera powered off"; never auto-resumes).
- `scripts/livestream-schedule.sh` — show/set the recurring livestream auto-start schedule (**live: Sundays 09:23**). Validates the calendar spec and writes a `livestream-autostart.timer` drop-in.
- `scripts/livestream-autostart.sh` — fired by `livestream-autostart.timer`; waits for a real camera frame, then starts the stream. The relay is **not** boot-enabled, so this and the manual scripts are the only automatic/deliberate start paths.
- `scripts/start-ffmpeg-display.sh` — ffplay fullscreen on DP-4.
- `scripts/soundbooth-health.sh` — Boot/ops diagnostics.
- `scripts/av-sync-calibrate.py` — Flash+beep A/V sync calibrator (measure / suggest `FFMPEG_AUDIO_DELAY_SEC`).
- `scripts/start-vlc.sh` — Optional **manual** VLC launcher (not a service; do not enable capture-on-boot).
- `patchbay/soundbooth.qpwgraph` — qpwgraph profile (Mixer→Presonus; Spotify→Mixer).
- `systemd/` — user units (`soundbooth.target`, FFmpeg stack, `ensure-audio-routes.service`, …).
- `ffmpeg-srt.conf.example` — template for `~/.config/soundbooth/ffmpeg-srt.conf` (shared by capture + relay).
- `camera.conf.example` — template for `~/.config/soundbooth/camera.conf` (real camera LAN IP; kept out of git).
- `livestream-schedule.conf.example` — template for `~/.config/soundbooth/livestream-schedule.conf` (tunes what happens when the schedule fires; the day/time itself lives in the timer — set it with `livestream-schedule.sh`).
- `atem.conf.example` — template for `~/.config/soundbooth/atem.conf` (real ATEM LAN IP; kept out of git).
- `tests/` — Manual verification steps.

## Boot chain (FOH)

1. Virtual sinks (pipewire-pulse) + `virtual-audio.service` (default → Mixer)
2. `qpwgraph.service` activates patchbay (`-a` only, never `-x`)
3. **`ensure-audio-routes.service`** re-asserts Mixer→Presonus (fixes boot races)
4. FFmpeg capture + display + livestream relay for program path (see `SYSTEM-STATE.md`)
5. **GUI apps (session autostart):** Spotify, FreeShow, browser — `autostart/soundbooth-*.desktop`  
   Install: `~/bin/install-booth-autostart.sh`
6. **Booth multiview (required / autostart):** `~/bin/start-booth-multiview.sh` — Wayland-safe 2×2 (FreeShow Primary/Stage + DP-4 + encode :5001); workspace 2  
   (`booth-multiview.py`; x11grab does **not** work under Mutter). Health **FAIL** if not running.

## Health check

```bash
~/bin/soundbooth-health.sh          # human report; exit 0=ok, 1=warn, 2=fail
~/bin/soundbooth-health.sh --quiet  # one-line summary
~/bin/soundbooth-health.sh --json   # machine-readable
audio-routing/tests/smoke-health.sh # non-interactive smoke (same exit codes)
```

Covers USB/ATEM/camera, displays, FFmpeg SRT + ffplay, FOH graph, program-audio,
multiview (encode feeder mid-stream flags + workspace patch), session autostart,
and browser-on-DP-1 when Vivaldi is running.

Livestream verify (browser): https://dashboard.subsplash.com/-d/#/media/live

### A/V lip-sync calibrator (optional — never automatic)

On-demand only. Not part of health/boot.

```bash
~/bin/av-sync-calibrate              # synthetic: prove adelay + detector (offline)
~/bin/av-sync-calibrate write-cal --input ~/Videos/soundbooth-av-cal.mkv
# Play cal full-screen into ATEM (set as program), then:
~/bin/av-sync-calibrate capture-udp  # record encode tee :5002, measure offset
~/bin/av-sync-calibrate capture-udp --apply-restart  # write conf + restart stack
```

- **synthetic** — generates flash+beep, encodes with production `adelay`, measures (does not change conf).
- **capture-udp** — samples live encode on **UDP :5002** (free probe tee; :5000=ffplay, :5001=multiview). Needs cal pattern on ATEM program for real path skew.
- Offset convention: audio−video ms; late audio → lower `FFMPEG_AUDIO_DELAY_SEC`.

Manual: `tests/manual-test.md`, multiview: `tests/multiview-checklist.md`.  
Project health: `audio-routing/scripts/soundbooth-health.sh` → install to `~/bin`.

See `../SYSTEM-STATE.md` for policies this script enforces.
