#!/usr/bin/env bash
# Install this repo onto the booth PC: scripts -> ~/bin, systemd --user units ->
# ~/.config/systemd/user, then enable exactly the set that should run.
#
# WHY THIS EXISTS
# Reproducibility on a fresh rebuild is a requirement, not a nice-to-have, and it
# used to depend on a prose checklist in REBUILD.md that had already drifted:
#   * `enable`-created .wants symlinks do NOT exist on a fresh machine, so units
#     wired only that way (the dashboard, HDMI previews, camera management,
#     ffmpeg-capture-watch) were never enabled by the documented flow;
#   * qpwgraph.service, virtual-sinks-loaded.target and ardour.service existed only
#     on the live box and were not in git at all, so a rebuild could not start them
#     even though soundbooth.target names the first two in its Wants=.
# A script that can also *verify* (--check) is the only version of this that stays
# honest, because it is runnable against the live machine any time.
#
# Usage:
#   install-soundbooth-system.sh            install + enable
#   install-soundbooth-system.sh --check    report drift, change nothing (exit 1 if any)
#   install-soundbooth-system.sh --no-enable  copy files only
#
# Safe to re-run. Never starts or stops anything: enabling only affects the next
# boot, so running this mid-service cannot interrupt a live stream.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${HOME}/bin"
UNITS="${HOME}/.config/systemd/user"

CHECK=0
ENABLE=1
for a in "$@"; do
    case "$a" in
        --check)     CHECK=1 ;;
        --no-enable) ENABLE=0 ;;
        -h|--help)   sed -n '2,28p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "ERROR: unknown argument '$a'" >&2; exit 2 ;;
    esac
done

DRIFT=0
note()  { echo "  $*"; }
drift() { echo "  DRIFT: $*"; DRIFT=1; }

# The [Install] WantedBy= target(s) an installed unit file currently
# declares, space-separated (comment lines are not matched — field 1 after
# splitting on "=" is "# WantedBy", not "WantedBy").
installed_wanted_by() {
    local unit_path="$1"
    [[ -f "$unit_path" ]] || return 0
    awk -F= '/^\[Install\]/{f=1; next} /^\[/{f=0} f && $1=="WantedBy"{ $1=""; print substr($0,2) }' "$unit_path"
}

# True if a unit's actual enable symlink(s) under ~/.config/systemd/user/*.wants/
# match exactly what its installed file's WantedBy= currently declares — no
# missing symlink, and no stale one left over from a WantedBy= that used to be
# different. `systemctl show -p UnitFileState` alone can't tell these apart: it
# reports "enabled" as long as ANY [Install] symlink exists for the unit,
# regardless of which target it's under. That gap let
# ffmpeg-capture-watch.service ship a fixed ordering-cycle bug (its WantedBy=
# changed from graphical-session.target to soundbooth.target) while the live
# machine kept running on the old graphical-session.target.wants/ symlink —
# `systemctl enable` was skipped because UnitFileState already read "enabled",
# so the new symlink was never created and the cycle stayed live (2026-09-13).
# (Deliberately not using `systemctl show -p WantedBy`: that property also
# includes any OTHER unit's own Wants= line naming this unit — e.g.
# soundbooth.target's static Wants= — which is a separate, legitimate
# mechanism this repo uses alongside [Install] and must not be flagged as
# drift. Comparing actual .wants/ symlinks against the file's own [Install]
# section avoids conflating the two.)
enablement_in_sync() {  # unit installed_unit_path
    local u="$1" path="$2" wanted target
    wanted="$(installed_wanted_by "$path")"
    [[ -z "$wanted" ]] && return 0   # no [Install] section — nothing to check
    for target in $wanted; do
        [[ -L "${UNITS}/${target}.wants/${u}" ]] || return 1
    done
    local d name found
    for d in "${UNITS}"/*.wants; do
        [[ -L "${d}/${u}" ]] || continue
        name="$(basename "$d")"; name="${name%.wants}"
        found=0
        for target in $wanted; do [[ "$name" == "$target" ]] && found=1; done
        (( found )) || return 1   # symlink under a target no longer in WantedBy=
    done
    return 0
}

# Scripts that live outside audio-routing/scripts, or install under a different
# name than their source file. "source::installed-name".
EXTRA_SCRIPTS=(
    "replicability/provision/backup-configs.sh::soundbooth-backup-configs.sh"
    "replicability/provision/restore-configs.sh::soundbooth-restore-configs.sh"
    "audio-routing/tests/smoke-health.sh::smoke-health.sh"
    # av-sync-calibrate.py is invoked as `av-sync-calibrate` (SYSTEM-STATE, health
    # output and the dashboard's CALIBRATE_SCRIPT all reference both spellings).
    "audio-routing/scripts/av-sync-calibrate.py::av-sync-calibrate"
)

# Repo scripts NOT installed to ~/bin: run from the repo, one-time helpers.
SKIP_SCRIPTS=( install-usb-reset-helper.sh install-soundbooth-system.sh )

# Units to enable. Each unit's own [Install] WantedBy decides where the symlink
# lands, so this is just the list — not a target mapping.
ENABLE_UNITS=(
    soundbooth.target
    virtual-audio.service
    qpwgraph.service
    ensure-audio-routes.service
    presonus-usb-watch.service
    lineout-fallback.service
    ffmpeg-capture.service
    ffmpeg-capture-watch.service
    ffmpeg-display.service
    ffmpeg-display-guard.service
    ffmpeg-srt-watch.service
    livestream-camera-watch.service
    livestream-autostart.timer
    camera-management.service
    camera-management-watch.service
    hdmi-preview.service
    hdmi-preview-dp4.service
    hdmi-preview-livestream.service
    soundbooth-dashboard.service
)

# Units that must exist but must NOT be enabled. Each has a reason; the check
# below is a real assertion, because getting these wrong is silently expensive.
#   ffmpeg-srt-relay.service  — enabling it streams to Subsplash at EVERY boot
#   ardour.service            — manual only (systemctl --user start ardour)
#   virtual-sinks-loaded.target — ordering anchor, pulled in via Requires=
MUST_NOT_ENABLE=( ffmpeg-srt-relay.service ardour.service virtual-sinks-loaded.target )

install_file() {  # src dst mode
    local src="$1" dst="$2" mode="$3"
    if [[ ! -f "$src" ]]; then drift "missing in repo: ${src#$REPO/}"; return; fi
    if [[ ! -f "$dst" ]]; then
        if (( CHECK )); then drift "not installed: ${dst/#$HOME/\~}"; else
            install -D -m "$mode" "$src" "$dst"; note "installed ${dst/#$HOME/\~}"; fi
    elif ! diff -q "$src" "$dst" >/dev/null 2>&1; then
        if (( CHECK )); then drift "differs from repo: ${dst/#$HOME/\~}"; else
            install -D -m "$mode" "$src" "$dst"; note "updated ${dst/#$HOME/\~}"; fi
    fi
}

echo "== scripts -> ${BIN/#$HOME/\~} =="
(( CHECK )) || mkdir -p "$BIN"
for f in "$REPO"/audio-routing/scripts/*.sh "$REPO"/audio-routing/scripts/*.py; do
    [[ -f "$f" ]] || continue
    b="$(basename "$f")"
    skip=0; for s in "${SKIP_SCRIPTS[@]}"; do [[ "$b" == "$s" ]] && skip=1; done
    (( skip )) && continue
    install_file "$f" "$BIN/$b" 0755
done
for pair in "${EXTRA_SCRIPTS[@]}"; do
    install_file "$REPO/${pair%%::*}" "$BIN/${pair##*::}" 0755
done

echo "== units -> ${UNITS/#$HOME/\~} =="
(( CHECK )) || mkdir -p "$UNITS"
for f in "$REPO"/audio-routing/systemd/*.service "$REPO"/audio-routing/systemd/*.target \
         "$REPO"/audio-routing/systemd/*.timer "$REPO"/dashboard/systemd/*.service; do
    [[ -f "$f" ]] || continue
    install_file "$f" "$UNITS/$(basename "$f")" 0644
done
# Drop-in stored flat in the repo as "<unit>.d-<name>.conf" -> "<unit>.d/<name>.conf".
for f in "$REPO"/audio-routing/systemd/*.service.d-*.conf; do
    [[ -f "$f" ]] || continue
    b="$(basename "$f")"
    install_file "$f" "${UNITS}/${b%%.d-*}.d/${b#*.d-}" 0644
done

if (( ENABLE )); then
    echo "== enable =="
    (( CHECK )) || systemctl --user daemon-reload
    for u in "${ENABLE_UNITS[@]}"; do
        state="$(systemctl --user show -p UnitFileState --value "$u" 2>/dev/null)"
        if [[ "$state" == "enabled" ]] && enablement_in_sync "$u" "${UNITS}/${u}"; then continue; fi
        if (( CHECK )); then
            if [[ "$state" != "enabled" ]]; then
                drift "not enabled: $u (${state:-missing})"
            else
                drift "enabled via a stale symlink, not this unit's current WantedBy=: $u"
            fi
        else
            # disable first so a stale symlink from a prior WantedBy= is removed,
            # then enable fresh against the just-installed unit file — plain
            # `enable` alone is a no-op once UnitFileState already says "enabled".
            systemctl --user disable "$u" >/dev/null 2>&1
            systemctl --user enable "$u" >/dev/null 2>&1 \
                && note "enabled $u" || drift "could not enable $u"
        fi
    done
    # Assertion, not a courtesy: a boot-enabled relay means every boot goes live.
    for u in "${MUST_NOT_ENABLE[@]}"; do
        state="$(systemctl --user show -p UnitFileState --value "$u" 2>/dev/null)"
        if [[ "$state" == "enabled" ]]; then
            drift "$u is ENABLED and must not be — run: systemctl --user disable $u"
        fi
    done
fi

echo
if (( DRIFT )); then
    if (( CHECK )); then
        echo "Drift found — re-run without --check to fix."
    else
        echo "Finished with problems above."
    fi
    exit 1
fi
(( CHECK )) && echo "In sync: installed state matches the repo." \
            || echo "Install complete. Nothing was started or stopped."
exit 0
