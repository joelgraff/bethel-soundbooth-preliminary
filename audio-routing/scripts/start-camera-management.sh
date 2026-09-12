#!/usr/bin/env bash
# Gate launch of the PTZOptics Camera Management Platform (CMP) on the
# camera actually being reachable on the network.
#
# Background: camera-management.service used to exec the Electron app
# directly. With the camera powered off, CMP's GPU/zygote process dies
# during its own shutdown handling every time systemd (re)starts it
# (status=5/TRAP, "GPU process isn't usable. Goodbye."), AND
# camera-management-watch.service separately force-restarts the service
# every ~150-180s because its :9999 RTSP-MPEG websocket never binds (no
# camera to transcode). Combined, that's a visible restart/flash loop on
# the booth screen for as long as the camera stays off — see STATUS.md
# 2026-09-04.
#
# This script waits (no window ever opens, nothing crashes) until the
# camera responds to ping, then execs the real binary so systemd tracks it
# exactly as before — Restart=on-failure still applies to a genuine
# post-launch crash once the app is actually running.
#
# Env (optional, or ~/.config/soundbooth/camera.conf):
#   CAMERA_NETWORK_IP              camera IP (default 192.168.1.202)
#   CAMERA_MGMT_WAIT_POLL_SEC      poll interval seconds while waiting (default 15)
#   CAMERA_MGMT_WAIT_LOG_EVERY     log a "still waiting" line every Nth poll (default 4, ~60s)
#   CAMERA_MGMT_WAIT_PROBE_TIMEOUT_SEC  RTSP frame-probe timeout (default 6)

set -uo pipefail

CAMERA_NETWORK_IP="${CAMERA_NETWORK_IP:-192.168.1.202}"
if [[ -f "${HOME}/.config/soundbooth/camera.conf" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.config/soundbooth/camera.conf" 2>/dev/null || true
    CAMERA_NETWORK_IP="${CAMERA_NETWORK_IP:-192.168.1.202}"
fi

POLL="${CAMERA_MGMT_WAIT_POLL_SEC:-15}"
LOG_EVERY="${CAMERA_MGMT_WAIT_LOG_EVERY:-4}"
PROBE_TIMEOUT="${CAMERA_MGMT_WAIT_PROBE_TIMEOUT_SEC:-6}"

log() { echo "[start-camera-management $(date +%H:%M:%S)] $*"; }

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

if ! camera_streaming; then
    log "camera ${CAMERA_NETWORK_IP} has no stream — waiting (no window will open until it does)"
    i=0
    until camera_streaming; do
        sleep "$POLL"
        i=$((i + 1))
        if (( i % LOG_EVERY == 0 )); then
            log "still waiting on camera ${CAMERA_NETWORK_IP}..."
        fi
    done
    log "camera ${CAMERA_NETWORK_IP} is streaming — launching CMP"
fi

cd "${HOME}/AppImage/Camera-Management-Platform-1.9.7.extracted" || exit 1
exec ./camera-management-platform --no-sandbox
