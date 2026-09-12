#!/bin/bash
# Ensure VLC stays on the configured output (default DP-4).
# Run as a systemd user service. Restarts vlc.service if the window
# drifts after HDMI hotplug / extender glitches / screen reordering,
# or if VLC came up before the preferred output existed at boot.

set -euo pipefail

# shellcheck disable=SC1091
source "$HOME/bin/vlc-display-lib.sh"
soundbooth_load_vlc_conf
soundbooth_export_display_env || true

log() { echo "[vlc-display-guard $(date +%H:%M:%S)] $*"; }

# Avoid restart thrash after we already fixed something
LAST_RESTART=0
MIN_RESTART_GAP=45
# Consecutive checks with active VLC but no discoverable window (headless / no XAUTH)
NO_WINDOW_STREAK=0
NO_WINDOW_RESTART_AFTER=3

maybe_restart_vlc() {
    local reason="$1"
    local now
    now=$(date +%s)
    if (( now - LAST_RESTART < MIN_RESTART_GAP )); then
        log "skip restart (debounce): $reason"
        return
    fi
    if ! systemctl --user is-enabled vlc.service &>/dev/null; then
        log "vlc.service not enabled; not restarting"
        return
    fi
    log "restarting vlc.service — $reason"
    systemctl --user restart vlc.service || log "restart failed"
    LAST_RESTART=$now
    NO_WINDOW_STREAK=0
}

check_once() {
    # Refresh X auth each loop (Mutter may create cookie after we started)
    if ! soundbooth_export_display_env 2>/dev/null; then
        log "no XAUTHORITY yet (waiting for Mutter Xwayland auth)"
        return
    fi

    if ! soundbooth_x_ready; then
        log "X display not ready (DISPLAY=${DISPLAY} XAUTHORITY=${XAUTHORITY:-unset})"
        return
    fi

    if ! soundbooth_preferred_connector_ready; then
        log "preferred connector ${PREFERRED_CONNECTOR} not resolvable yet — waiting"
        return
    fi

    if ! systemctl --user is-active --quiet vlc.service; then
        NO_WINDOW_STREAK=0
        # VLC not running; if unit is enabled, nudge it once displays are ready
        if systemctl --user is-enabled vlc.service &>/dev/null; then
            local st
            st=$(systemctl --user is-active vlc.service 2>/dev/null || true)
            if [[ "$st" == "activating" || "$st" == "auto-restart" || "$st" == "failed" ]]; then
                log "vlc.service state=${st}; displays ready — restart to pick up ${PREFERRED_CONNECTOR}"
                maybe_restart_vlc "vlc not active but displays ready"
            fi
        fi
        return
    fi

    # Active VLC but no window: often started without XAUTHORITY (headless encode only)
    # or window not yet mapped. After a few checks, force restart so start-vlc re-resolves.
    if [[ -z "$(soundbooth_vlc_window_xy)" ]]; then
        NO_WINDOW_STREAK=$((NO_WINDOW_STREAK + 1))
        if (( NO_WINDOW_STREAK >= NO_WINDOW_RESTART_AFTER )); then
            log "VLC active but no window for ${NO_WINDOW_STREAK} checks (XAUTHORITY=${XAUTHORITY:-unset})"
            maybe_restart_vlc "no VLC window while service active"
        fi
        return
    fi
    NO_WINDOW_STREAK=0

    MON=$(soundbooth_resolve_vlc_monitor || true)
    if [[ -z "$MON" ]]; then
        log "cannot resolve target monitor"
        return
    fi
    local idx conn w h x y
    read -r idx conn w h x y <<<"$MON"

    # Also catch "started with wrong qt screen" via process cmdline vs resolve
    local vlc_cmd qt_screen
    vlc_cmd=$(ps -eo args= 2>/dev/null | grep -E '[/]usr/bin/vlc ' | head -1 || true)
    qt_screen=$(echo "$vlc_cmd" | grep -oE 'qt-fullscreen-screennumber=[0-9]+' | head -1 | cut -d= -f2 || true)
    if [[ -n "$qt_screen" && "$qt_screen" != "$idx" ]]; then
        log "VLC qt-screen=${qt_screen} != resolved ${conn} index ${idx}"
        maybe_restart_vlc "qt-screen desync (${qt_screen}→${idx} ${conn})"
        return
    fi

    if soundbooth_vlc_on_monitor "$x" "$y" "$w" "$h"; then
        return
    fi

    local vxy
    vxy=$(soundbooth_vlc_window_xy)
    log "VLC at ${vxy} not on ${conn} (${w}x${h}+${x}+${y})"
    maybe_restart_vlc "window off ${conn}"
}

log "started; prefer=${PREFERRED_CONNECTOR} interval=${GUARD_INTERVAL}s"
# First checks more often so boot races self-heal quickly
for _ in 1 2 3 4 5 6; do
    check_once || true
    sleep 5
done
while true; do
    check_once || true
    sleep "$GUARD_INTERVAL"
done
