#!/bin/bash
# Restart program display only if ffplay process is actually gone.
# Do NOT use xlsclients/wmctrl — under GNOME Wayland ffplay often does not
# appear there, which caused a restart loop and focus-stealing.
set -euo pipefail

INTERVAL="${FFMPEG_GUARD_INTERVAL_SEC:-30}"
# Minimum seconds between restarts (debounce)
MIN_RESTART_GAP="${FFMPEG_GUARD_MIN_RESTART_GAP:-60}"
LAST_RESTART=0

log() { echo "[ffmpeg-display-guard $(date +%H:%M:%S)] $*"; }

while true; do
    sleep "$INTERVAL"

    if ! systemctl --user is-active --quiet ffmpeg-capture.service 2>/dev/null; then
        continue
    fi

    # Only manage display if the unit is enabled or already active
    if ! systemctl --user is-enabled --quiet ffmpeg-display.service 2>/dev/null \
        && ! systemctl --user is-active --quiet ffmpeg-display.service 2>/dev/null; then
        continue
    fi

    if pgrep -x ffplay &>/dev/null; then
        continue
    fi

    now=$(date +%s)
    if (( now - LAST_RESTART < MIN_RESTART_GAP )); then
        log "ffplay missing but restart debounced (${MIN_RESTART_GAP}s)"
        continue
    fi

    log "ffplay process missing while ffmpeg-capture active — restarting ffmpeg-display"
    systemctl --user restart ffmpeg-display.service || log "restart failed"
    LAST_RESTART=$now
done
