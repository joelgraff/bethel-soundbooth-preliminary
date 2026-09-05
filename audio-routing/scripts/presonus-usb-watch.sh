#!/bin/bash
# presonus-usb-watch.sh — Watch the PreSonus 32SX for FOH-silencing failures
# that don't show up as a simple "service crashed" — restart the bridge to
# force recovery, same debounce/cap pattern as the other *-watch.sh scripts
# in this repo (camera-management-watch.sh, ffmpeg-capture-watch.sh).
#
# Built 2026-09-04 after a night of recurring FOH silence with every
# individual signal looking healthy in isolation. Three real failure modes
# were found, none of which any single existing check caught on its own:
#
#   1. `amixer -c N cget` (StudioLive Internal Clock Validity) can itself
#      be stale — it read "on" while the kernel log showed live, repeated
#      usb_set_interface/clock-source failures on every retry (20:38).
#   2. The kernel log can be completely clean, `amixer` can say "on", and
#      the board's physical meter can still be dead (21:00) — the
#      USB link and ALSA driver state both look fine while the aplay
#      process had gone stale relative to a since-reset connection.
#   3. The deepest one: ALSA's hw_ptr (actual hardware playback position)
#      can freeze — state stays RUNNING, no kernel error, `amixer` says
#      "on" — while the device has silently stopped consuming audio
#      entirely (21:03). This script's hw_ptr check is the only one of
#      the three that catches this specific mode.
#
# None of these are reliably distinguishable from a single check — this
# script ORs all three together, and DOES NOT treat any one of them alone
# as sufficient proof of health.
#
# Env (optional, conf or service Environment=):
#   PRESONUS_WATCH_POLL_SEC        poll interval seconds (default 15)
#   PRESONUS_WATCH_MIN_GAP_SEC     debounce between restarts (default 60)
#   PRESONUS_WATCH_MAX_PER_HOUR    cap restarts (default 10 — this board is
#                                  known to need frequent recovery some
#                                  nights; the cap is a backstop, not a
#                                  expected-frequency target)
#   PRESONUS_WATCH_DISABLE=1       no-op loop (for testing)
#
# systemctl --user status presonus-usb-watch.service

set -uo pipefail

POLL="${PRESONUS_WATCH_POLL_SEC:-15}"
MIN_GAP="${PRESONUS_WATCH_MIN_GAP_SEC:-60}"
MAX_HOUR="${PRESONUS_WATCH_MAX_PER_HOUR:-10}"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/soundbooth-presonus-usb-watch"
mkdir -p "$STATE_DIR"
RESTART_LOG="${STATE_DIR}/restarts.log"

log() { echo "[presonus-usb-watch $(date +%H:%M:%S)] $*"; }

card_num() {
    aplay -l 2>/dev/null | awk '/S32SX/{ match($0,/card ([0-9]+)/,a); print a[1]; exit }'
}

count_restarts_last_hour() {
    local cutoff now
    now=$(date +%s)
    cutoff=$((now - 3600))
    [[ -f "$RESTART_LOG" ]] || { echo 0; return; }
    awk -v c="$cutoff" '$1 >= c { n++ } END { print n+0 }' "$RESTART_LOG"
}

record_restart() {
    date +%s >> "$RESTART_LOG"
    if [[ -f "$RESTART_LOG" ]] && [[ "$(wc -l < "$RESTART_LOG")" -gt 200 ]]; then
        tail -n 100 "$RESTART_LOG" > "${RESTART_LOG}.tmp" && mv "${RESTART_LOG}.tmp" "$RESTART_LOG"
    fi
}

do_restart() {
    local reason="$1" now n
    if [[ "${PRESONUS_WATCH_DISABLE:-0}" == "1" ]]; then
        log "DISABLE set — would restart for: $reason"
        return
    fi
    now=$(date +%s)
    if [[ -n "${LAST_RESTART:-}" ]] && (( now - LAST_RESTART < MIN_GAP )); then
        log "debounced (${MIN_GAP}s) — $reason"
        return
    fi
    n=$(count_restarts_last_hour)
    if (( n >= MAX_HOUR )); then
        log "MAX restarts/hour (${MAX_HOUR}) reached — NOT restarting ($reason)." \
            "This almost certainly needs a physical power-cycle of the board, not another software restart."
        return
    fi
    log "restarting presonus-foh-bridge (${reason}) [hour count $((n + 1))/${MAX_HOUR}]"
    if systemctl --user restart presonus-foh-bridge.service; then
        LAST_RESTART=$now
        record_restart
    else
        log "ERROR: systemctl restart presonus-foh-bridge failed"
    fi
}

log "watching PreSonus 32SX (amixer + kernel log + hw_ptr) — poll ${POLL}s, min gap ${MIN_GAP}s, max ${MAX_HOUR}/h"

LAST_STATE="unknown"
while true; do
    sleep "$POLL"

    CARD=$(card_num)
    if [[ -z "$CARD" ]]; then
        # Board not enumerated at all — genuinely down, not just degraded.
        STATE="bad"
        REASON="card not present"
    else
        AMIXER_OK=false
        amixer -c "$CARD" cget numid=1 2>/dev/null | grep -q "values=on" && AMIXER_OK=true

        KERNEL_BAD=false
        if journalctl -k --since "-${POLL}sec" --no-pager 2>/dev/null | \
            grep -qE "usb_set_interface failed|clock source.*is not valid|cannot get freq \(v2/v3\)|device descriptor read/64, error|USB disconnect"; then
            KERNEL_BAD=true
        fi

        # hw_ptr is a ring-buffer position (wraps every ~20ms during
        # normal playback), so it's only meaningful sampled twice within
        # one short window, not across the full poll interval.
        HWPTR_STUCK=false
        PCM_STATUS="/proc/asound/card${CARD}/pcm0p/sub0/status"
        if [[ -r "$PCM_STATUS" ]]; then
            READ1=$(cat "$PCM_STATUS" 2>/dev/null)
            STATE1=$(echo "$READ1" | awk -F': *' '/^state/{print $2}')
            PTR1=$(echo "$READ1" | awk -F': *' '/^hw_ptr/{print $2}')
            sleep 1.5
            READ2=$(cat "$PCM_STATUS" 2>/dev/null)
            STATE2=$(echo "$READ2" | awk -F': *' '/^state/{print $2}')
            PTR2=$(echo "$READ2" | awk -F': *' '/^hw_ptr/{print $2}')
            if [[ "$STATE1" == "RUNNING" && "$STATE2" == "RUNNING" && -n "$PTR1" && "$PTR1" == "$PTR2" ]]; then
                HWPTR_STUCK=true
            fi
        fi

        if $AMIXER_OK && ! $KERNEL_BAD && ! $HWPTR_STUCK; then
            STATE="ok"
        else
            STATE="bad"
            REASON="amixer_ok=$AMIXER_OK kernel_bad=$KERNEL_BAD hwptr_stuck=$HWPTR_STUCK"
        fi
    fi

    if [[ "$STATE" == "bad" && "$LAST_STATE" == "ok" ]]; then
        log "ALERT: PreSonus 32SX unhealthy ($REASON)"
        do_restart "$REASON"
    elif [[ "$STATE" == "bad" ]]; then
        # Still bad on a later poll — try another restart if debounce allows
        # (covers the case where a software restart alone won't fix it, but
        # is still worth attempting periodically in case it does).
        do_restart "$REASON (still bad)"
    fi
    if [[ "$STATE" == "ok" && "$LAST_STATE" == "bad" ]]; then
        log "RECOVERED"
    fi
    LAST_STATE="$STATE"
done
