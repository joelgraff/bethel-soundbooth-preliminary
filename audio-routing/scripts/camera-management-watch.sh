#!/usr/bin/env bash
# Watch camera-management (CMP) for a "process alive but RTSP-MPEG pipeline
# never started" stuck state, and restart the service.
#
# Background: camera-management.service has Restart=on-failure, which only
# helps if the process exits. On 2026-08-23 the process stayed "active" for
# ~2h48m after a camera power-cycle while its internal RTSP→MPEG1 transcode
# never (re)started — no crash, no exit, just a silently dead preview pipeline
# (:9999 never bound). Nothing paged anyone; it was only caught because a
# human happened to run soundbooth-health.sh. This watcher exists so that
# case self-heals instead of waiting on a human.
#
# Unlike ffmpeg-srt-watch.sh, there is no reliable ongoing journal failure
# signature to tail here — CMP logs "No route to host" only on its very first
# RTSP attempt at service start, not on subsequent silent non-(re)connects.
# So this polls systemctl active-state + TCP :9999 bind on an interval
# instead of tailing the journal.
#
# Env (optional, conf or service Environment=):
#   CAMERA_MGMT_WATCH_POLL_SEC        poll interval seconds (default 30)
#   CAMERA_MGMT_WATCH_GRACE_SEC       grace after (re)start before acting (default 150)
#   CAMERA_MGMT_WATCH_MIN_GAP_SEC     debounce between restarts (default 180)
#   CAMERA_MGMT_WATCH_MAX_PER_HOUR    cap restarts (default 4)
#   CAMERA_MGMT_WATCH_PORT            websocket port to check (default 9999)
#   CAMERA_MGMT_WATCH_DISABLE=1       no-op loop (for testing)
#
# systemctl --user status camera-management-watch.service

set -uo pipefail

POLL="${CAMERA_MGMT_WATCH_POLL_SEC:-30}"
GRACE="${CAMERA_MGMT_WATCH_GRACE_SEC:-150}"
MIN_GAP="${CAMERA_MGMT_WATCH_MIN_GAP_SEC:-180}"
MAX_HOUR="${CAMERA_MGMT_WATCH_MAX_PER_HOUR:-4}"
PORT="${CAMERA_MGMT_WATCH_PORT:-9999}"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/soundbooth-camera-management-watch"
mkdir -p "$STATE_DIR"
RESTART_LOG="${STATE_DIR}/restarts.log"

log() { echo "[camera-management-watch $(date +%H:%M:%S)] $*"; }

port_bound() {
    ss -tln 2>/dev/null | grep -qE ":${PORT}([[:space:]]|\$)"
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
    local reason="$1"
    local now n

    if [[ "${CAMERA_MGMT_WATCH_DISABLE:-0}" == "1" ]]; then
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
            "Investigate manually: systemctl --user restart camera-management"
        return
    fi

    log "CMP stuck (${reason}) — restarting camera-management.service [hour count $((n + 1))/${MAX_HOUR}]"
    if systemctl --user restart camera-management.service; then
        LAST_RESTART=$now
        record_restart
        log "restart issued OK"
    else
        log "ERROR: systemctl restart camera-management failed"
    fi
}

log "watching camera-management.service :${PORT} bind (poll ${POLL}s, grace ${GRACE}s, min gap ${MIN_GAP}s, max ${MAX_HOUR}/h)"

while true; do
    sleep "$POLL"

    if ! systemctl --user is-active --quiet camera-management.service 2>/dev/null; then
        # Not our problem — either intentionally stopped, or systemd
        # Restart=on-failure is already handling a process death.
        continue
    fi

    active_since=$(systemctl --user show camera-management.service -p ActiveEnterTimestamp --value 2>/dev/null || true)
    if [[ -z "$active_since" || "$active_since" == "n/a" ]]; then
        continue
    fi
    active_since_ts=$(date -d "$active_since" +%s 2>/dev/null) || continue

    now=$(date +%s)
    age=$((now - active_since_ts))
    if (( age < GRACE )); then
        continue
    fi

    if port_bound; then
        continue
    fi

    do_restart ":${PORT} not bound ${age}s after service (re)start (grace ${GRACE}s)"
done
