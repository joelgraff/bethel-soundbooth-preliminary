# Multiview regression checklist

Run after changes to `booth-multiview.py`, `start-ffmpeg-capture.sh` (local tee),
display layout, or Auto Move workspace patch.

## Automated (health)

```bash
~/bin/start-booth-multiview.sh
sleep 8
~/bin/soundbooth-health.sh 2>&1 | sed -n '/--- multiview ---/,/^---/p'
```

Required PASS when multiview is running:
- [ ] Source connectors DP-2, DP-3, DP-4
- [ ] FFmpeg **producer** tees UDP :5001
- [ ] Process running + encode feeder child
- [ ] Encode feeder mid-stream probe flags (`analyzeduration` / `probesize`)
- [ ] Window “Soundbooth Multiview” present
- [ ] Auto Move workspace patch present

## Manual pixels (workspace 2)

| # | Tile | Pass criteria |
|---|------|----------------|
| 1 | Primary/FOH | FreeShow Primary content (not Grok/desktop) |
| 2 | Stage | FreeShow Stage content |
| 3 | Program DP-4 | ATEM program; may show windows really on DP-4 |
| 4 | FFmpeg encode | Matches program video; **not black**; no browser UI |

## Encode tile black (regression)

Cause: feeder joined mid-stream without H.264 headers.

```bash
# Producer has 5001?
pgrep -af 'ffmpeg.*video0' | grep -q 5001 && echo producer_ok

# Feeder flags?
pgrep -P "$(cat $XDG_RUNTIME_DIR/soundbooth-multiview/multiview.pid)" -a | grep -E 'probesize|analyzeduration'
```

Fix: update `booth-multiview.py`, reinstall to `~/bin`, restart multiview.

## Workspace (Wayland)

- [ ] Multiview on workspace **2** (Super+Page_Down / Super+Alt+2)
- [ ] Ops apps (FreeShow editor, browser) on workspace **1**
- If stuck: `~/bin/configure-multiview-workspace.sh` then Super+Shift+Page_Down once

## Negative tests

- [ ] Stop multiview → health **FAIL** “Multiview not running” (required for Sunday ops)
- [ ] Autostart: `~/.config/autostart/soundbooth-multiview.desktop` present after `install-booth-autostart.sh`
- [ ] Disconnect nothing on Sunday; only WARN if a connector is truly missing
