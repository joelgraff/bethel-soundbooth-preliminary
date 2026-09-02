# Display / VLC investigation — 2026-07-12 (post-service)

## Summary

Two separate problems stacked:

1. **Display assignment:** VLC is fullscreen on the **same output as FreeShow Stage** (DP-3 / HDbitT HDMI-over-Ethernet). The likely VLC TV (**DP-4 / SII HDMI TV**) only shows the Ubuntu desktop.
2. **Capture source gone:** The ATEM Mini Extreme **does not appear on USB** and **`/dev/video*` does not exist**. VLC is looping `v4l2 demux error: dequeue error: No such device`. HDMI **audio** can still play because VLC also opens a Pulse/ATEM audio slave independently of the video node.

GNOME `~/.config/monitors.xml` layout (positions/connectors) still matches the live `xrandr` geometry. The fragile piece is **VLC’s hardcoded screen index**, not a corrupted monitors.xml.

## Current physical map (live)

| Connector | EDID (from monitors.xml) | Position | Role now |
|-----------|--------------------------|----------|----------|
| DP-1 | SAM S34CG50 (ultrawide) | +1920+1080, 3440×1440 | Primary booth monitor |
| DP-2 | HXA **BMD HDMI** | +2789+0, 1920×1080 | FreeShow **Primary** output |
| DP-3 | LKV **HDbitT** (HDMI-over-Eth) | +5360+1080, 1920×1080 | FreeShow **Stage** + **VLC** (stacked) |
| DP-4 | SII **HDMI TV** | +0+1080, 1920×1080 | **Desktop only** (no fullscreen app) |

Window evidence (`xwininfo`):

- FreeShow `Stage` → `1920x1080+5360+1080`
- FreeShow `Primary` → `1920x1080+2789+0`
- VLC `v4l2:///dev/video0` → `1920x1080+5360+1080` (**same as Stage**)

## How VLC picks a display

`~/bin/start-vlc.sh` and the unit description:

```text
--qt-fullscreen-screennumber=3
```

Unit: `vlc.service` — “VLC UVC Capture to Display 3”.

That index is **ordinal**, not “connector DP-4”. Under Wayland + XWayland, Qt’s screen order can disagree with `xrandr --listmonitors` and **shifts when an output drops/reconnects** (exactly what HDMI-over-Ethernet and TV power cycles do).

`xrandr` order right now:

- 0 = DP-1 booth  
- 1 = DP-4 SII HDMI TV  
- 2 = DP-3 HDbitT  
- 3 = DP-2 BMD HDMI  

VLC was started **08:19** and never restarted. After morning hotplug events, its window is on **DP-3**, not on DP-4.

FreeShow is more resilient: it stores **bounds + screen IDs** (`settings.json` outputs Primary `screen: "35"` / Stage `screen: "37"`). After reconnect, Stage is again on HDbitT; Primary on BMD HDMI.

## Why audio without video

VLC command line (abbreviated):

- Video: `v4l2:///dev/video0` ← **device missing**
- Audio slave: `pulse://alsa_input.usb-Blackmagic_Design_ATEM_Mini_Extreme_...`
- Also streams HTTP `:8081/stream.ts`

No Blackmagic device in `lsusb` at investigation time. Continuous journal errors:

```text
v4l2 demux error: dequeue error: No such device
```

So even a correct screen would show black/no picture until ATEM UVC is restored; audio path can still feed HDMI.

## Related signals from today

- Kernel around **14:14**: EDID read error on **DP-2** (`No EDID read`) — consistent with flaky HDMI/extender/BMD path.
- USB **3-2** churn earlier; PreSonus re-enumerated ~14:15. ATEM not present on bus now.

## Root causes (contributing)

1. **Fragile display targeting** — numeric `--qt-fullscreen-screennumber=N` instead of connector/EDID (e.g. “SII HDMI TV” / DP-4).
2. **Long-lived VLC process** — does not re-bind when monitors hotplug; stays on wrong/outdated screen.
3. **HDMI-over-Ethernet drop** — HDbitT path flaked (matches user report); compositor re-layout + FreeShow re-output; VLC not re-laid out correctly relative to intended TV.
4. **ATEM UVC missing** — independent hardware/USB issue; explains blank video content even where VLC is drawn (and under Stage it is not visible anyway).
5. **Collision** — VLC and Stage share DP-3; Stage wins visually.

## What is *not* broken

- `monitors.xml` 4-display configuration still matches live positions for the full layout.
- FreeShow Stage is on the intended HDbitT output again (user-confirmed working).
- PipeWire HDMI sinks still exist for the AMD card (`HDMI 0`…`HDMI 4`).

## Recommended fixes (not applied during investigation)

1. **Hardware:** Power-cycle / reseat ATEM Mini Extreme USB; confirm `lsusb` shows Blackmagic and `/dev/video0` (or correct node) returns.
2. **Immediate software:** When ATEM is back, restart VLC after confirming display map:  
   `systemctl --user restart vlc.service`  
   Temporarily set screen number to the index of **DP-4** if that is the sanctuary VLC TV (verify in Settings → Displays), **or** move the window onto DP-4 geometry `+0+1080`.
3. **Hardening:** Change `start-vlc.sh` to resolve screen by **connector or EDID product name** (e.g. prefer `SII` / `HDMI TV` / DP-4), wait until that output is connected, then launch; optional: restart VLC on DRM hotplug.
4. **Ops:** Document “after any TV/extender glitch: check Displays layout, FreeShow outputs, restart VLC.”
5. **Do not** rely on screen index `3` across reboots/hotplug.

## Commands used

```bash
xrandr --listmonitors
xwininfo -root -tree | grep -iE 'Stage|Primary|VLC'
cat ~/.config/monitors.xml
systemctl --user status vlc.service
# FreeShow: ~/.config/freeshow/settings.json → outputs
lsusb; ls /dev/video*
```

---

## Follow-up: XAUTHORITY subshell regression (2026-07-12 evening)

Connector resolve + wait for DP-4 was implemented, but cold-start still put VLC on the **booth desktop** (or headless encode-only).

**Symptom in journal:**

```text
Display ready after 4s (XAUTHORITY=/run/user/.../.mutter-Xwaylandauth....)
...
X11: DISPLAY=:0 XAUTHORITY=unset
Authorization required, but no authorization protocol specified
```

**Cause:** `start-vlc.sh` used `MON=$(soundbooth_wait_for_vlc_display)`. Bash runs command substitution in a **subshell**, so `export XAUTHORITY` inside the wait never reached the parent. VLC was `exec`'d without the Mutter cookie. Health could still show “resolved DP-4” from a later shell that *did* have auth.

**Fix:**

- `soundbooth_wait_for_vlc_display_into MON` (nameref — same shell)
- Re-export + require `XAUTHORITY` file before `exec vlc`
- Guard: restart if `vlc.service` is active but no window for several checks
- `StartLimitIntervalSec` / `StartLimitBurst` moved to `[Unit]` (were ignored under `[Service]`)

**Verify:** `xwininfo` window at `1920x1080+0+1080` (DP-4); health **PASS** `VLC window geometry on DP-4`.
