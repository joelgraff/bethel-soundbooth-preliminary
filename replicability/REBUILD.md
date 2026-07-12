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
systemctl --user enable --now soundbooth.target qpwgraph.service vlc.service ardour.service
```

Run:
```
~/bin/ensure-audio-routes.sh
qpwgraph -a ~/patchbay_profile/soundbooth.qpwgraph
```

Test software audio (Spotify/browser) goes to the board. VLC goes to HDMI TVs.

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
