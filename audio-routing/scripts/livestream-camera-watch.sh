#!/usr/bin/env bash
# Auto-end the Subsplash livestream if the program camera goes unreachable.
#
# The camera at CAMERA_NETWORK_IP is the same physical unit whose SDI output
# feeds the ATEM's program input. It is NOT based on ATEM/video0 presence:
# the ATEM and booth PC typically stay powered well after the camera itself
# is switched off, so /dev/video0 never disappears in the normal
# end-of-service sequence.
#
# ICMP ping alone is NOT sufficient (disproven by live test 2026-08-30): this
# camera's network interface stays up and its RTSP server keeps answering
# DESCRIBE/handshake requests even when the video encoder itself is off — the
# SDP negotiation succeeds but zero RTP video packets are ever delivered. So
# health is judged by actually pulling one frame over RTSP, not just pinging.
#
# This is a *complement* to ~/bin/stop-live-stream.sh, not a replacement:
# without it, the livestream would otherwise sit dead-air on Subsplash from
# whenever the camera is powered off until someone remembers to run
# stop-live-stream.sh (or up to Subsplash's own 8h timeout).
#
# Only ever STOPS the relay — never restarts it when the camera comes back.
# Resuming a live broadcast is always a deliberate operator action:
# ~/bin/start-live-stream.sh.
#
# Env (optional, ~/.config/soundbooth/camera.conf or service Environment=):
#   CAMERA_NETWORK_IP              camera IP to ping (default 192.168.1.202)
#   LIVESTREAM_CAMERA_POLL_SEC     poll interval (default 15)
#   LIVESTREAM_CAMERA_GRACE_SEC    seconds unreachable before ending stream (default 60)
#   LIVESTREAM_CAMERA_WATCH_DISABLE=1   no-op loop (for testing)
#   LIVESTREAM_CAMERA_PROBE_TIMEOUT_SEC RTSP frame-probe timeout (default 6)
#
# systemctl --user status livestream-camera-watch.service

set -uo pipefail

if [[ -f "${HOME}/.config/soundbooth/camera.conf" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.config/soundbooth/camera.conf" 2>/dev/null || true
fi
CAMERA_NETWORK_IP="${CAMERA_NETWORK_IP:-192.168.1.202}"

POLL="${LIVESTREAM_CAMERA_POLL_SEC:-15}"
GRACE="${LIVESTREAM_CAMERA_GRACE_SEC:-60}"
PROBE_TIMEOUT="${LIVESTREAM_CAMERA_PROBE_TIMEOUT_SEC:-6}"

log() { echo "[livestream-camera-watch $(date +%H:%M:%S)] $*"; }

# Ping is a fast pre-check for a fully-dead network path. It is NOT
# sufficient on its own — this camera's RTSP server keeps responding even
# with the video encoder off — so a ping success falls through to an actual
# frame pull below before being trusted.
camera_reachable() {
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

down_since=0
ended_for_this_outage=0

log "watching camera ${CAMERA_NETWORK_IP} — will end livestream after ${GRACE}s unreachable"

while true; do
    sleep "$POLL"

    if [[ "${LIVESTREAM_CAMERA_WATCH_DISABLE:-0}" == "1" ]]; then
        continue
    fi

    if camera_reachable; then
        if [[ "$down_since" -ne 0 ]]; then
            log "camera reachable again (${CAMERA_NETWORK_IP})"
        fi
        down_since=0
        ended_for_this_outage=0
        continue
    fi

    now=$(date +%s)
    if [[ "$down_since" -eq 0 ]]; then
        down_since=$now
        log "camera unreachable (${CAMERA_NETWORK_IP}) — starting ${GRACE}s grace period"
        continue
    fi

    elapsed=$((now - down_since))
    if [[ "$elapsed" -lt "$GRACE" ]]; then
        continue
    fi

    # Only act once per outage — don't spam stop-live-stream.sh every poll
    # while the camera stays down.
    if [[ "$ended_for_this_outage" -eq 1 ]]; then
        continue
    fi

    if ! systemctl --user is-active --quiet ffmpeg-srt-relay.service 2>/dev/null; then
        log "livestream already stopped — nothing to do"
        ended_for_this_outage=1
        continue
    fi

    log "camera unreachable for ${elapsed}s — ending livestream"
    if "${HOME}/bin/stop-live-stream.sh"; then
        log "livestream ended OK"
    else
        log "ERROR: stop-live-stream.sh failed"
    fi
    ended_for_this_outage=1
done
