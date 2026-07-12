# Soundbooth Quick Reference

## Golden Rule (Audio)
**Every app that makes sound goes to the Presonus 32SX board by default.**

Exception: **VLC** is routed to the AMD HDMI outputs to drive the sanctuary TVs.

## Common Software Sources
- Spotify (snap)
- Web browsers (Vivaldi, Firefox, Chromium)
- Any other desktop media player

They should appear automatically on the board (via the Mixer virtual sink).

## How to Check Routing
1. Open qpwgraph (or it auto-starts).
2. Look for the app name (spotify, Chromium-..., etc.).
3. It should be connected toward "Mixer" → Presonus AUX.
4. Run: `~/bin/ensure-audio-routes.sh`
5. Listen / watch board meters.

## Useful Commands
```bash
# Restart audio stack safely
systemctl --user restart wireplumber pipewire

# Force routes
~/bin/ensure-audio-routes.sh

# See current graph
pw-link -l | grep -iE 'mixer|presonus|spotify|chromium'

# Status of services
systemctl --user status qpwgraph vlc ardour
```

## Startup Order
1. Power on Presonus 32SX.
2. Boot / login to the soundbooth computer.
3. qpwgraph, VLC capture, Ardour should come up via systemd user services.
4. Test a software source (Spotify or browser) — it should be on the board.

## If Audio Is Missing from Board
- Run the ensure script.
- Check qpwgraph and manually connect if needed (temporary).
- Restart wireplumber.
- Verify Presonus is detected: `pactl list short sinks | grep -i presonus`

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

## VLC for TVs
VLC is intentionally sent to HDMI outputs  for the big screens. Do not expect it on the FOH mixer.
