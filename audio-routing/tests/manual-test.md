# Soundbooth manual tests (audio + Sunday stack)

Align with **SYSTEM-STATE.md**. Prefer `~/bin/soundbooth-health.sh` first (exit 0/1/2).

---

## 0) Automated smoke (every change / boot)

```bash
# Full human report
~/bin/soundbooth-health.sh

# Exit code only: 0=ok, 1=warn, 2=fail
~/bin/soundbooth-health.sh --quiet; echo exit:$?

# Or:
~/soundbooth-project/audio-routing/tests/smoke-health.sh
```

**Success:** exit 0 (or 1 only for known optional WARNs you accept). **Fail (2)** must be fixed before service.

### After editing soundbooth-health.sh itself

```bash
~/soundbooth-project/audio-routing/tests/health-check-unit-tests.sh
```

Fixture-based regression tests for individual `check_*` functions (fake
`systemctl`/`lsusb`/`ss`, no live hardware needed) — catches parsing
regressions before they'd otherwise only surface as a silent live mis-report.

### After editing av-sync-calibrate.py

```bash
~/soundbooth-project/audio-routing/tests/av-sync-calibrate-test.sh
```

Offline regression test for synthetic-mode delay measurement accuracy
(no ATEM/hardware needed).

---

## 1) Software audio → Mixer → Presonus (FOH)

### Prerequisites
- Presonus 32SX on and visible (`pactl list short sinks | grep -i presonus`)
- Health: **foh-graph** PASS, default sink Mixer

### Steps
1. `systemctl --user restart ensure-audio-routes.service` (or `~/bin/ensure-audio-routes.sh`)
2. Play Spotify **or** browser HTML5 audio (not program path).
3. Confirm:
   - Board meters / FOH hear it
   - `pw-link -l | grep -iE 'spotify|chromium|vivaldi|mixer|presonus'`
   - Health **audio-route** PASS for active streams

### Success
- Apps on **Mixer**, Mixer→**Presonus AUX0/1** linked without manual qpwgraph each launch.
- qpwgraph uses **`-a` only** (never exclusive `-x`).

---

## 2) Program path: FFmpeg SRT + ffplay DP-4

### Steps
1. Health: **program-display**, **stream**, **program-audio** all PASS.
2. Sanctuary TV (DP-4) shows ATEM program; lipsync acceptable.
3. Browser: [Subsplash live](https://dashboard.subsplash.com/-d/#/media/live) shows stream when event is armed.
4. Confirm **no** VLC user services: health **No VLC user services**.

### Optional: automated lip-sync test (manual only — not part of boot/health)

**Do not run on every boot.** Use when tuning `FFMPEG_AUDIO_DELAY_SEC` or verifying adelay.

```bash
# Offline (safe): flash+beep → encode with current delay → measure
~/bin/av-sync-calibrate

# Live path: write cal, play into ATEM program, then capture encode tee :5002
~/bin/av-sync-calibrate write-cal --input ~/Videos/soundbooth-av-cal.mkv
~/bin/av-sync-calibrate capture-udp
# Apply only if intentional:
# ~/bin/av-sync-calibrate capture-udp --apply-restart
```

Grok skill (on request): `/av-sync-calibrate`  
Skill doc: `.grok/skills/av-sync-calibrate/SKILL.md`

### Failures
| Symptom | Fix |
|---------|-----|
| Blank TV | `systemctl --user restart ffmpeg-display` |
| No stream / no video0 | Wait for device; `systemctl --user restart ffmpeg-capture ffmpeg-display` |
| Intermittent audio | `journalctl --user -u ffmpeg-capture -b \| grep -iE 'alsa\|xrun'` |
| ffplay on Mixer (FOH) | `ensure-audio-routes` / restart ffmpeg-display |
| Subsplash not receiving (TV still fine) | `systemctl --user status ffmpeg-srt-relay`; resume with `~/bin/start-live-stream.sh` |

---

## 3) Session autostart (Spotify, FreeShow, browser)

### After login / reboot
1. Health **session-apps**: all three `soundbooth-*.desktop` PASS.
2. Spotify, FreeShow, Vivaldi launch (delays 8–12s by design).
3. **Browser on DP-1** (booth ultrawide), **not** program DP-4:
   - Health PASS: `Vivaldi window on booth side…`
   - Or relaunch: `~/bin/start-booth-browser.sh`

### Reinstall autostart
```bash
~/bin/install-booth-autostart.sh
```

---

## 4) Booth multiview

### Prerequisites
- FreeShow Primary (DP-2) + Stage (DP-3) showing content
- `ffmpeg-capture` tees **:5001** (health multiview PASS)
- Auto Move patch present (health PASS workspace patch)

### Start
```bash
~/bin/start-booth-multiview.sh
# workspace 2: Super+Page_Down or Super+Alt+2
```

### Health (when running)
| Check | Expect |
|-------|--------|
| Source connectors DP-2/3/4 | PASS |
| Producer tees :5001 | PASS |
| Process + ffmpeg child | PASS |
| Encode feeder mid-stream flags | PASS (`analyzeduration`/`probesize`) |
| Window present | PASS |
| Workspace patch | PASS |

### Eyeball (not automated)
| Tile | Expect |
|------|--------|
| 1 Primary/FOH | FreeShow Primary slide/video (not booth desktop/terminal) |
| 2 Stage | FreeShow Stage |
| 3 Program DP-4 | Sanctuary feed (+ any window really on DP-4) |
| 4 FFmpeg encode | Same program content **without** browser chrome; not black |

### Encode tile black
- Feeder must use mid-stream probe flags (health WARN if not).
- Restart multiview after fix: `~/bin/start-booth-multiview.sh`
- Confirm producer: `pgrep -af ffmpeg | grep 5001`

### Workspace stuck on 1
```bash
~/bin/configure-multiview-workspace.sh
# Focus Multiview once: Super+Shift+Page_Down
```

---

## 5) FreeShow media

- Prefer **MP4/H.264** (VP9/webm stutters on WX 3200).
- Helpers: `~/bin/convert-for-freeshow.sh`, `yt-dlp-freeshow.sh`
- Outputs: Primary=DP-2, Stage=DP-3 (not program DP-4).

---

## 6) Cold reboot (Sunday-like)

1. Presonus on before/with PC.
2. Reboot; wait for graphical login + network.
3. Run `~/bin/soundbooth-health.sh` (or Sunday Grok session).
4. Confirm FFmpeg stack active, FOH graph PASS, displays 4-head.
5. Start FreeShow if not autostarted; multiview should autostart (~18s) or `~/bin/start-booth-multiview.sh`.
6. Spot-check Subsplash + sanctuary TV.

### Success
- No FAIL on health.
- Autostart apps up; browser on DP-1.
- Program TV + multiview (ws2) correct.

---

## If something is wrong

| Area | Action |
|------|--------|
| FOH silent | `~/bin/ensure-audio-routes.sh` |
| Default sink | `pactl set-default-sink Mixer` |
| Program | `systemctl --user restart ffmpeg-capture ffmpeg-display` |
| Livestream stuck / need to end it | `~/bin/stop-live-stream.sh` (end) / `~/bin/start-live-stream.sh` (resume) |
| Multiview | `~/bin/start-booth-multiview.sh` |
| Workspace patch | `~/bin/configure-multiview-workspace.sh` |
| Browser on wrong screen | `~/bin/start-booth-browser.sh` |
| WirePlumber rule | copy from `audio-routing/wireplumber/` → restart wireplumber |

**Source of truth:** `SYSTEM-STATE.md` + project tree under `soundbooth-project/audio-routing/`.
