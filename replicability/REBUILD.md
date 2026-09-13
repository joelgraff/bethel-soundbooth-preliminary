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
- `~/bin` and `~/.config/systemd/user` are installed **from this repo** in step 6 —
  don't restore those from backup, or you'll reintroduce whatever drifted on the old
  machine. (That has already happened once: `~/bin` carried real LAN IPs long after
  the repo had externalised them.)
- Restore from backup only what is genuinely not in git: `~/.config/pipewire*`,
  `~/.config/soundbooth/*.conf` (real IPs / SRT streamid), `~/patchbay_profile`,
  `~/.config/monitors.xml`, `~/.config/freeshow`.
- Or use the `backup-configs.sh` / `restore-configs.sh` pair once they are completed.
- Copy Documents, Ardour (templates + important sessions), FreeShow shows from separate media backup.

## 5. Hardware bring-up
- Connect PreSonus 32SX **and power it on** before or during the first boot of the services.
- Multiple HDMI outputs for TVs, ATEM capture, etc.
- Reboot.

## 6. Enable & test services
One command installs scripts to `~/bin`, units to `~/.config/systemd/user`, and
enables exactly the right set:

```
./audio-routing/scripts/install-soundbooth-system.sh
```

Then reboot (or log out and back in) so the user session starts them.

**Do not hand-copy units instead.** The previous instructions here copied unit files
and enabled only `soundbooth.target`, which did *not* reproduce this machine: the
`.wants` symlinks that `enable` creates don't exist on a fresh box, so everything
wired only that way — the dashboard, HDMI previews, camera management,
`ffmpeg-capture-watch` — was never enabled at all.

Verify at any time, including against a running booth (read-only, exits 1 on drift):

```
./audio-routing/scripts/install-soundbooth-system.sh --check
~/bin/livestream-schedule.sh      # expect "Sun *-*-* 09:23:00" + a next run
```

Two things the installer deliberately does **not** enable, and asserts stay that way:

- **`ffmpeg-srt-relay.service`** — enabling it streams to Subsplash at *every* boot.
  It is `static`; the stream starts only via `~/bin/start-live-stream.sh`, the
  `livestream-autostart.timer` schedule, or the dashboard button.
- **`ardour.service`** — manual only: `systemctl --user start ardour.service`.

Do NOT install or enable `vlc.service` — ATEM UVC is exclusive; the program path is FFmpeg.

Real values for `~/.config/soundbooth/*.conf` (SRT streamid, camera and ATEM LAN IPs)
are **not** in git — copy them from the config backup, or from the `*.conf.example`
templates. Scripts fall back to RFC-5737 placeholder addresses, so a missing
`camera.conf` fails in a confusing way rather than loudly.

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
