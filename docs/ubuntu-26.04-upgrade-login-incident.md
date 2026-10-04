# Ubuntu 24.04 → 26.04 upgrade: GDM login loop, and what else the upgrade broke

Investigation note, not architecture truth — see `SYSTEM-STATE.md` for what is
live (its "Ubuntu 26.04 upgrade" section is the short version of this file).
Written 2026-10-04 from the system and user journals of the boots that day.
Statements marked **(inferred)** were not directly observed in a log.

## Symptom

After the release upgrade, GDM would not keep a session for `soundbooth`. The
session opened and closed again within 1–3 seconds, every time, with
`gnome-session-init-worker` logging:

    A graphical session is already running!

Stopping `graphical-session.target` by hand (`systemctl --user stop`) let a login
succeed once. It came back on every boot.

## Timeline (all 2026-10-04, CDT)

| Time | Event |
|------|-------|
| 11:25 | Boot on **24.04** (GNOME 46). **Autologin** works. |
| 13:22 | Manual re-login via `gdm-password` works (still 24.04). |
| 13:32–13:55 | `do-release-upgrade` (`/var/log/dist-upgrade/`; `/etc/lsb-release` rewritten 13:36). GDM stopped 13:55:41. |
| 13:56 | First **26.04** boot (GNOME Shell **50.1**). Autologin session opens and closes in ~3 s; three password logins each close in ~1 s. Same on the next three boots (14:01, 14:05, 14:08). |
| 14:13 | `/etc/gdm3/custom.conf` modified: `AutomaticLoginEnable` / `AutomaticLogin=soundbooth` are now commented out. Presumably a troubleshooting step by the operator — not done by an agent. **Autologin is still off.** |
| 14:28 | Unit fix applied (below). |
| 14:33 | Reboot: login via `gdm-password` at 14:34:02 succeeds. Fix confirmed. |

## Root cause

Two things combined; neither alone would have broken login.

1. **The booth's login process starts the user manager before anyone logs in.**
   `soundbooth` has `Linger=yes`, so `user@1000` starts at boot and pulls in
   `default.target` → `soundbooth.target` → `qpwgraph`, `ffmpeg-capture`, and the rest
   of the stack, with no GNOME session. Five of those units declared
   `Wants=` / `Requires=graphical-session.target` (`ardour`, `qpwgraph`,
   `soundbooth-dashboard`, `hdmi-preview`, `camera-management`). Those *activate* the
   target, so `graphical-session.target` was already **active** in the lingering
   manager before GDM had started GNOME.
2. **The 26.04 GNOME session refuses to start when that target is already active.**
   GNOME 50's `gnome-session` is fully systemd-managed, and
   `gnome-session-init-worker` aborts with "A graphical session is already running!".
   **(inferred)** The 24.04 session (`gnome-session-binary`, GNOME 46) never made
   that check, which is why the same units had worked for months. The journal on 24.04
   boots shows no such message; every 26.04 boot before the fix does.

## Fix

`Wants=`/`Requires=graphical-session.target` → `PartOf=graphical-session.target`
in those five units; `qpwgraph` `WantedBy=default.target` → `graphical-session.target`
(`reenable`d). Repo copies in `audio-routing/systemd/` and `dashboard/systemd/`
updated. `After=` and `WantedBy=graphical-session.target` stay — they are correct.
The ordering-cycle rules in `ffmpeg-capture-watch`, `ffmpeg-srt-watch` and
`camera-management-watch` are untouched. Pre-change backup:
`~/systemd-user-backup-20261004-142803`.

**Rule for the future:** no user unit may `Wants=`, `Requires=`, `BindsTo=` or
`Upholds=` `graphical-session.target`. Check with
`grep -rE '^(Wants|Requires|BindsTo|Upholds)=.*graphical-session' ~/.config/systemd/user`.
Vendor GNOME units in `/usr/lib/systemd/user` legitimately do; leave them alone.

## Other post-upgrade problems found in the logs (NOT fixed)

Ordered by how much they matter on a Sunday.

1. **Dashboard was down — FIXED 2026-10-04 14:39.** `soundbooth-dashboard.service` crash-loops with
   `ModuleNotFoundError: No module named 'uvicorn'`. `dashboard/backend/.venv` was
   built on Python 3.12; the system is now 3.14.4 and the venv's `bin/python` resolves to
   it, while the packages sit under `lib/python3.12`. Fix: recreate the venv
   (`python3 -m venv --clear .venv`, reinstall the dashboard requirements). It is the
   only venv in the tree. The dashboard carries the livestream start/stop button.
   Fix applied: new venv built with system 3.14 from `requirements.txt` (unpinned, so
   newer fastapi 0.142 / anthropic 1.11 than before; all `app.*` modules import, service
   serves HTTP 200). Old venv kept as `dashboard/backend/.venv.py312.bak` — delete once
   satisfied. The live agent chat path (Anthropic SDK jump 1.4 → 1.11) is untested.
2. **WirePlumber 0.5 ignored our Lua rules — PORTED 2026-10-04; ATEM rule verified live, PreSonus rule not.** The box now has WirePlumber 0.5.13 /
   PipeWire 1.6.2; the journal says "Lua configuration files are NOT supported in
   WirePlumber 0.5". `~/.config/wireplumber/main.lua.d/51-presonus-soft-mixer.lua`
   and `52-atem-audio-ignore.lua` therefore do nothing. Observed: PipeWire now owns the
   ATEM's audio card (`alsa_card.usb-Blackmagic_Design_ATEM_Mini_Extreme…` appears in
   `pactl list cards`), which `52-` existed to prevent — the cause of the old
   "Device or resource busy" capture race. `ffmpeg-capture` won the race this boot, so
   it is a latent risk, not a current fault. Both rules were ported to
   `wireplumber.conf.d/*.conf` (SPA-JSON; `~` = glob, confirmed from libwireplumber symbols and the
   vendor config; `device.disabled` still honoured, `monitors/alsa.lua:485`). Syntax-checked with
   `spa-json-dump`. Applied by restarting WirePlumber at 14:42 (room quiet, no stream): ATEM card dropped
   out of PipeWire as intended; `ffplay` (input #251) stayed on the HDMI sink in every poll from
   t+1s on; health check clean apart from PreSonus. `ffplay-audio-guard` fired at 14:42:18 when
   the HDMI sink briefly vanished — its park-on-LocalLive call failed (stream momentarily
   unmovable) but the stream came back to HDMI on its own; a sub-second leak to Mixer during the
   restart gap can't be ruled out, the polls didn't start until t+1s. Restart is therefore
   *low* risk but not zero — still avoid mid-service. The PreSonus rule can't be
   exercised until the board is back on USB. The installer now deploys the `.conf` files and
   flags any leftover `main.lua.d/*.lua` as drift (before this it never installed WirePlumber
   files at all — they had been hand-copied). All WirePlumber 0.4.17 claims in
   `SYSTEM-STATE.md` (including the `ffplay` fallback behaviour) are unverified on 0.5.
3. **GNOME user extensions were disabled — FIXED 2026-10-04 ~14:45.**
   `org.gnome.shell disable-user-extensions` was `true` (who/what set it is unknown; nothing in the
   logs). Set to `false` live: `tilingshell` and `auto-move-windows` went ACTIVE, no shell errors.
   `auto-move-windows` is already upstream 50.4 (the repo's `auto-move-windows-soundbooth-patch/`
   targets the retired Multiview — obsolete, don't reapply). `soundbooth-multiview-workspace`
   only listed shell 46: metadata now `["46","50"]` and a `ws.index` bug fixed (it is a method, so
   the old check always re-moved and logged every 3s). It still shows OUT OF DATE because GNOME
   caches metadata at shell start; it loads on the next login. Until then the stock Auto Move
   `application-list` entry places the dashboard, but only for newly-created windows.
   `tiling-assistant` and `tilingshell` are both enabled, as before the upgrade (the cockpit plan
   wants `tiling-assistant` dropped — not done).
4. **Autologin is off** (see 14:13 above). If the booth is meant to come up unattended
   it will now sit at the GDM greeter. Re-enabling is two lines in
   `/etc/gdm3/custom.conf` and needs root; deliberately not done by an agent. Note
   `gkr-pam: couldn't unlock the login keyring` appears under autologin (no password) —
   it did on 24.04 too, so apps that use the keyring may prompt.
5. **`presonus-foh-bridge` is failing in a restart loop** and `lsusb` shows no PreSonus
   at all, so the board is off or unplugged right now. Looks like power, not the
   upgrade; `presonus-usb-watch` had already been asking for a power-cycle.
6. **Low priority / cosmetic:** `autorandr.service` is `failed (start-limit-hit)` (no
   `~/.config/autorandr` profiles exist, so it has nothing to apply; `autorandr.desktop`
   also exited 1 on the old boot); GNOME wallpaper `picture-uri` is empty, so
   gnome-shell logs "Failed to load background file:///home/soundbooth"; a `sound.target`
   "destructive transaction" warning from the user manager at boot (cause not
   identified, nothing visibly affected); `spice-vdagent.service` unknown key warning,
   Dash-to-Dock `st_widget_get_theme_node` spam, and `could not set nice-level` from
   PipeWire (cause not investigated) — all noise so far.

## How to diagnose a recurrence

    journalctl -b -g 'already running'                 # the signature
    journalctl --user -b | grep -iE 'ordering cycle'   # cycle regressions
    systemctl --user list-dependencies --reverse graphical-session.target
    systemctl --user show -p Wants -p Requires graphical-session.target

If the target is active in the lingering manager *before* the login time in
`journalctl -u gdm`, something is activating it — find it with the
`list-dependencies --reverse` line above.
