# Rebuild from Fresh Ubuntu

This document (together with the `provision/` scripts) lets you recreate the soundbooth computer.

## 1. Fresh OS
- Install Ubuntu Desktop (match current version, e.g. 24.04).
- During install create user `soundbooth`.
- After first boot, update:
  ```
  sudo apt update && sudo apt full-upgrade -y
  ```

## 2. Get the project
Copy the entire `soundbooth-project/` directory from backup / external drive / git clone.

Recommended final location on the machine:
`/home/soundbooth/soundbooth-project/`

## 3. Run provision
```
cd soundbooth-project/replicability/provision
./install.sh
```

This installs packages, snaps, and notes the unused ollama/webui cleanup.

## 4. Restore user configuration
- Restore `~/.config/pipewire*`, `~/.config/systemd/user`, `~/bin`, `~/patchbay_profile`, etc.
- Or use the `backup-configs.sh` / `restore-configs.sh` pair once they are completed.
- Copy Documents, Ardour (templates + important sessions), FreeShow shows from separate media backup.

## 5. Hardware bring-up
- Connect PreSonus 32SX **and power it on** before or during the first boot of the services.
- Multiple HDMI outputs for TVs, ATEM capture, etc.
- Reboot.

## 6. Enable & test services
```
# From project units (also under audio-routing/systemd/):
cp audio-routing/systemd/*.service audio-routing/systemd/*.target \
  ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now soundbooth.target
# soundbooth.target pulls: qpwgraph, ensure-audio-routes, ffmpeg-capture, ffmpeg-srt-relay, ffmpeg-display, guard, livestream-camera-watch
# Optional multitrack only when needed: systemctl --user start ardour.service
# Do NOT install or enable vlc.service — ATEM UVC is exclusive; program path is FFmpeg
```

Run:
```
~/bin/soundbooth-health.sh
# Expect PASS on foh-graph (Mixer → Presonus AUX0/1)
```

Test software audio (Spotify/browser) goes to the board (Mixer/Presonus).
Program: ATEM → ffmpeg-capture (local UDP tees) → ffplay on DP-4 (HDMI TV audio, not Mixer)
                                                 → ffmpeg-srt-relay → SRT → Subsplash.
End livestream now / resume: `~/bin/stop-live-stream.sh` / `~/bin/start-live-stream.sh`
(capture + TV keep running either way).
Livestream verify: https://dashboard.subsplash.com/-d/#/media/live

## 7. Git (recommended)
```
cd ~/soundbooth-project
git init
git add .
git commit -m "Initial soundbooth setup from $(date)"
```

## 8. Future
As the soundbooth-setup system matures, this REBUILD process will be driven by a single command that also performs source/sink discovery and applies the routing policy automatically.

See the top-level README and STATUS.md.
