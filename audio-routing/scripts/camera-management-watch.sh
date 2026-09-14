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
#   CAMERA_NETWORK_IP                 camera IP (default 192.0.2.202)
#   CAMERA_MGMT_WATCH_PROBE_TIMEOUT_SEC  RTSP frame-probe timeout (default 6)
#   CAMERA_MGMT_WATCH_DISABLE=1       no-op loop (for testing)
#
# systemctl --user status camera-management-watch.service

set -uo pipefail

POLL="${CAMERA_MGMT_WATCH_POLL_SEC:-30}"
GRACE="${CAMERA_MGMT_WATCH_GRACE_SEC:-150}"
MIN_GAP="${CAMERA_MGMT_WATCH_MIN_GAP_SEC:-180}"
MAX_HOUR="${CAMERA_MGMT_WATCH_MAX_PER_HOUR:-4}"
PORT="${CAMERA_MGMT_WATCH_PORT:-9999}"
CAMERA_NETWORK_IP="${CAMERA_NETWORK_IP:-192.0.2.202}"
PROBE_TIMEOUT="${CAMERA_MGMT_WATCH_PROBE_TIMEOUT_SEC:-6}"
if [[ -f "${HOME}/.config/soundbooth/camera.conf" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.config/soundbooth/camera.conf" 2>/dev/null || true
    CAMERA_NETWORK_IP="${CAMERA_NETWORK_IP:-192.0.2.202}"
fi
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/soundbooth-camera-management-watch"
mkdir -p "$STATE_DIR"
RESTART_LOG="${STATE_DIR}/restarts.log"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/soundbooth-watch-lib.sh"

log() { echo "[camera-management-watch $(date +%H:%M:%S)] $*"; }

port_bound() {
    ss -tln 2>/dev/null | grep -qE ":${PORT}([[:space:]]|\$)"
}

# Ping is a fast pre-check for a fully-dead network path. It is NOT
# sufficient on its own — this camera's RTSP server keeps responding even
# with the video encoder off (see livestream-camera-watch.sh) — so a ping
# success falls through to an actual frame pull before being trusted.
camera_streaming() {
    if ! ping -c 1 -W 1 "$CAMERA_NETWORK_IP" >/dev/null 2>&1; then
        return 1
    fi

    local probe_file
    probe_file="$(mktemp --suffix=.jpg 2>/dev/null)" || return 1
    timeout "$PROBE_TIMEOUT" ffmpeg -y -loglevel error -rtsp_transport tcp \
        -i "rtsp://${CAMERA_NETWORK_IP}" -frames:v 1 -q:v 2 "$probe_file" \
        >/dev/null 2>&1
    local got_frame=1
    [[ -s "$probe_file" ]] && got_frame=0
    rm -f "$probe_file"
    return "$got_frame"
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

    n=$(count_restarts_last_hour "$RESTART_LOG")
    if (( n >= MAX_HOUR )); then
        log "MAX restarts/hour (${MAX_HOUR}) reached — NOT restarting ($reason)." \
            "Investigate manually: systemctl --user restart camera-management"
        return
    fi

    log "CMP stuck (${reason}) — restarting camera-management.service [hour count $((n + 1))/${MAX_HOUR}]"
    if systemctl --user restart camera-management.service; then
        LAST_RESTART=$now
        record_restart "$RESTART_LOG"
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

    if ! camera_streaming; then
        # Camera has no active stream — :9999 not binding is expected
        # (start-camera-management.sh is waiting on the camera, or CMP has
        # nothing to transcode), not a stuck pipeline. Don't restart.
        continue
    fi

    do_restart ":${PORT} not bound ${age}s after service (re)start (grace ${GRACE}s)"
done
