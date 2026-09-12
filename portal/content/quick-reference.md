# Soundbooth Quick Reference

## Golden Rule (Audio)
**Every app that makes sound goes to the Presonus 32SX board by default** (via the **Mixer** virtual sink).

**Program path exception:** FFmpeg/ffplay (sanctuary TV + livestream) uses **HDMI TV on DP-4**, not the FOH Mixer.

Optional **VLC** as a normal media player is fine; it is **not** a boot service and must not take over ATEM capture.

## Common Software Sources
- Spotify (snap)
- Web browsers (Vivaldi, Firefox, Chromium)
- FreeShow media audio
- Any other desktop media player

They should appear automatically on the board (via the Mixer virtual sink → Presonus AUX0/1).

**FreeShow volume:** master level is in `~/.config/freeshow/settings.json` → `"volume": 1.0` (was **0.1** = 10%, which made it very quiet). PipeWire sets both FreeShow and Spotify to **33%** via `~/bin/ensure-audio-routes.sh` — this is loud, not quiet: the FOH path now passes at clean unity gain end-to-end (2026-08-02 fix), and modern streaming/media masters are loud enough that 33% is a comfortable working level on the board. If it's ever too quiet or too hot again, re-tune by ear with `pavucontrol` (Spotify's slider matches its PipeWire volume directly; FreeShow's own in-app volume should stay at 100% and the *PipeWire* stream level is the one to adjust) and update `FREESHOW_VOLUME_PCT`/`SOFTWARE_VOLUME_PCT` in `ensure-audio-routes.sh` to match. Board preamp/gain trim does nothing for this channel (USB return, not analog input) — use the board's channel **fader** instead.

## How to Check Routing
1. Open qpwgraph (or it auto-starts).
2. Look for the app name (spotify, Chromium-..., etc.).
3. It should be connected toward **Mixer → Presonus AUX0/1**.
4. Run: `~/bin/ensure-audio-routes.sh`
5. Listen / watch board meters.
6. Full check: `~/bin/soundbooth-health.sh` (includes **FOH graph** Mixer→board).

## Livestream + sanctuary TV (FFmpeg stack)
- Capture: `systemctl --user status ffmpeg-capture` — ATEM → local UDP tees (display, multiview, livestream). Always-on; does not touch Subsplash directly.
- Livestream: `systemctl --user status ffmpeg-srt-relay` — the only thing that talks to **SRT (Subsplash)**
- Display: `systemctl --user status ffmpeg-display` — **ffplay** video on **DP-4**, **audio on HDMI TV** (not FOH Mixer)
- Config: `~/.config/soundbooth/ffmpeg-srt.conf` (shared by capture + relay)
- Restart capture + TV (does not touch livestream): `systemctl --user restart ffmpeg-capture.service ffmpeg-display.service`
- **End the livestream now** (e.g. end of service — Subsplash otherwise stays live up to 8h): `~/bin/stop-live-stream.sh`
- **Resume the livestream:** `~/bin/start-live-stream.sh`
- **Auto-end on camera off:** if the camera goes unreachable on the network for 60s (e.g. powered off), the stream ends by itself (`livestream-camera-watch.service`). It never auto-resumes — always restart manually.
- **Verify livestream in browser:** https://dashboard.subsplash.com/-d/#/media/live  
- Subsplash “connected but no video”: re-arm the live event, then restart `ffmpeg-srt-relay` once

## Useful Commands
```bash
# Full booth health (USB, ATEM, DP-4, SRT, FOH Mixer→Presonus, services)
~/bin/soundbooth-health.sh

# Force FOH routes (apps→Mixer and Mixer→Presonus)
~/bin/ensure-audio-routes.sh

# See current graph
pw-link -l | grep -iE 'mixer|presonus|spotify|chromium|ffplay'

# Core services
systemctl --user status soundbooth.target ffmpeg-capture ffmpeg-srt-relay ffmpeg-display qpwgraph ensure-audio-routes

# End / resume the livestream only (capture + TV keep running)
~/bin/stop-live-stream.sh
~/bin/start-live-stream.sh

# Optional multitrack recording (off by default)
systemctl --user start ardour.service
```

## Startup Order
1. Power on Presonus 32SX.
2. Boot / login to the soundbooth computer.
3. qpwgraph, ensure-audio-routes, FFmpeg SRT + ffplay come up via `soundbooth.target`.
4. Test a software source (Spotify or browser) — it should be on the board.
5. Optional: open Subsplash dashboard to confirm livestream.

## If Audio Is Missing from Board
- Run `~/bin/ensure-audio-routes.sh` (most common: Mixer→Presonus links missing).
- Check qpwgraph: **Mixer monitor → Presonus AUX0/1**.
- Restart wireplumber only if needed: `systemctl --user restart wireplumber`.
- Verify Presonus: `pactl list short sinks | grep -i presonus`
- Health: `~/bin/soundbooth-health.sh` — look for **foh-graph** FAIL.

## FreeShow Media Playback (webm vs mp4)
- **MP4 (H.264)** plays smoothly (uses hardware decode on the AMD WX 3200).
- **WebM (VP9)** often stutters/skips (this GPU has **no VP9 hardware decode**).
- **Convert one file**:
  ```
  ~/bin/convert-for-freeshow.sh "/path/to/clip.webm"
  ```
  Writes a sibling `.mp4` (H.264 + AAC).
- **Convert everything under Downloads** (skips files that already have an mp4):
  ```
  ~/bin/convert-for-freeshow-batch.sh
  ~/bin/convert-for-freeshow-batch.sh ~/path/to/media
  ```
- **Download for FreeShow** (prefer MP4/H.264):
  ```
  ~/bin/yt-dlp-freeshow.sh "https://..."
  ```
- Optional launcher: `~/bin/start-freeshow.sh`
- **Already converted (2026-07-12):**
  - `Downloads/Skit Guys - Being Mom [H-Kw6cOwh2c].mp4`
  - `Downloads/yt-dlp_linux (2)/Girls Captain…2026….mp4`
  In FreeShow, use these `.mp4` files instead of the `.webm` originals.

## Config Backup / Restore
```bash
# Snapshot bin, project, wireplumber, pipewire, systemd user units, patchbay
~/bin/soundbooth-backup-configs.sh

# Restore from a dated archive (creates a pre-restore safety copy)
~/bin/soundbooth-restore-configs.sh ~/soundbooth-project/replicability/backups/soundbooth-config-….tar.gz
```

## Displays
| Connector | Role |
|-----------|------|
| DP-1 | Booth ultrawide (primary) |
| DP-2 | FreeShow **Primary** (BMD HDMI) |
| DP-3 | FreeShow **Stage** (extender) |
| DP-4 | Program **ffplay** → sanctuary HDMI TV |

After HDMI extender glitches: check Displays; `systemctl --user restart ffmpeg-display.service`; re-check FreeShow outputs.

## Ardour
Off by default. When you need multitrack: `systemctl --user start ardour.service`.
