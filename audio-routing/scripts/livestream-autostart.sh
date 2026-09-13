#!/usr/bin/env bash
# Scheduled start of the Subsplash livestream (fired by livestream-autostart.timer).
#
# The livestream leg (ffmpeg-srt-relay.service) is deliberately NOT enabled at
# boot — see SYSTEM-STATE.md. It starts exactly three ways:
#   1. ~/bin/start-live-stream.sh          (manual)
#   2. livestream-autostart.timer          (this script — recurring schedule)
#   3. dashboard livestream start button   (confirm-gated)
#
# WHY THIS WAITS FOR THE CAMERA INSTEAD OF JUST STARTING THE RELAY
# livestream-camera-watch.service ends the stream after ~75s (15s poll + 60s
# grace) whenever the program camera isn't delivering frames. So a bare
# "start the relay at 09:23" trigger would fire, push dead air to Subsplash,
# and then get shut down a minute later if the camera hadn't been switched on
# yet — leaving the operator with a stream that mysteriously refused to stay
# up. Instead this waits for a real frame, then starts. The two features agree
# on what "camera is live" means rather than racing each other.
#
# Exits 0 even when it gives up, on purpose: a failed oneshot would sit red in
# `systemctl --user status` and the dashboard for the rest of the week over a
# Sunday where someone simply never powered the camera on. The journal line is
# the signal instead.
#
# Env (optional, ~/.config/soundbooth/livestream-schedule.conf or Environment=):
#   LIVESTREAM_AUTOSTART_DISABLE=1        no-op (kills the schedule without disabling the timer)
#   LIVESTREAM_AUTOSTART_CAMERA_WAIT_SEC  how long to wait for a camera frame (default 1200 = 20 min)
#   LIVESTREAM_AUTOSTART_POLL_SEC         poll interval while waiting (default 15)
#   LIVESTREAM_AUTOSTART_REQUIRE_CAMERA   1 (default) = don't start without a frame; 0 = start anyway
#   LIVESTREAM_AUTOSTART_PROBE_TIMEOUT_SEC  RTSP frame-probe timeout (default 6)
#   CAMERA_NETWORK_IP                     camera IP (normally from camera.conf)
#
# systemctl --user status livestream-autostart.service
# Schedule:  ~/bin/livestream-schedule.sh

set -uo pipefail

# Precedence is env > conf > default. The conf files use plain assignments —
# camera.conf hard-sets CAMERA_NETWORK_IP — so sourcing them CLOBBERS anything
# passed in the environment or via the unit's Environment=. Capture the env
# values first and reapply them after sourcing. Same idiom as
# soundbooth-health.sh; without it, overriding the camera IP for a dry run
# silently probes the real camera instead.
_env_camera_ip="${CAMERA_NETWORK_IP:-}"
_env_disable="${LIVESTREAM_AUTOSTART_DISABLE:-}"
_env_wait="${LIVESTREAM_AUTOSTART_CAMERA_WAIT_SEC:-}"
_env_poll="${LIVESTREAM_AUTOSTART_POLL_SEC:-}"
_env_require="${LIVESTREAM_AUTOSTART_REQUIRE_CAMERA:-}"
_env_probe="${LIVESTREAM_AUTOSTART_PROBE_TIMEOUT_SEC:-}"

for conf in camera.conf livestream-schedule.conf; do
    if [[ -f "${HOME}/.config/soundbooth/${conf}" ]]; then
        # shellcheck disable=SC1090
        source "${HOME}/.config/soundbooth/${conf}" 2>/dev/null || true
    fi
done

CAMERA_NETWORK_IP="${_env_camera_ip:-${CAMERA_NETWORK_IP:-192.0.2.202}}"
DISABLE="${_env_disable:-${LIVESTREAM_AUTOSTART_DISABLE:-0}}"
CAMERA_WAIT="${_env_wait:-${LIVESTREAM_AUTOSTART_CAMERA_WAIT_SEC:-1200}}"
POLL="${_env_poll:-${LIVESTREAM_AUTOSTART_POLL_SEC:-15}}"
REQUIRE_CAMERA="${_env_require:-${LIVESTREAM_AUTOSTART_REQUIRE_CAMERA:-1}}"
PROBE_TIMEOUT="${_env_probe:-${LIVESTREAM_AUTOSTART_PROBE_TIMEOUT_SEC:-6}}"

log() { echo "[livestream-autostart $(date +%H:%M:%S)] $*"; }

if [[ "$DISABLE" == "1" ]]; then
    log "LIVESTREAM_AUTOSTART_DISABLE=1 — scheduled start suppressed"
    exit 0
fi

if systemctl --user is-active --quiet ffmpeg-srt-relay.service 2>/dev/null; then
    log "livestream already running — nothing to do"
    exit 0
fi

# Duplicated from livestream-camera-watch.sh on purpose: that script is the
# canonical copy and runs as a live service, so it is not refactored into a
# shared library just for this caller. Keep the two in sync if the probe
# changes. Ping alone is NOT sufficient — this camera's RTSP server answers
# DESCRIBE with the video encoder off and delivers zero RTP packets
# (disproven by live test 2026-08-30), so health means actually pulling a frame.
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

start_stream() {
    log "starting livestream via start-live-stream.sh"
    if "${HOME}/bin/start-live-stream.sh"; then
        log "livestream started OK"
    else
        log "ERROR: start-live-stream.sh failed (exit $?)"
    fi
}

if [[ "$REQUIRE_CAMERA" != "1" ]]; then
    log "REQUIRE_CAMERA=0 — starting without checking the camera"
    start_stream
    exit 0
fi

log "waiting up to ${CAMERA_WAIT}s for a frame from camera ${CAMERA_NETWORK_IP}"
deadline=$(( $(date +%s) + CAMERA_WAIT ))

while true; do
    if camera_reachable; then
        log "camera is delivering frames"
        start_stream
        exit 0
    fi

    # Someone may have started the stream by hand while we were waiting.
    if systemctl --user is-active --quiet ffmpeg-srt-relay.service 2>/dev/null; then
        log "livestream started by someone else while waiting — standing down"
        exit 0
    fi

    now=$(date +%s)
    if (( now >= deadline )); then
        log "WARNING: no camera frame within ${CAMERA_WAIT}s — livestream NOT started."
        log "  Power on the program camera, then: ~/bin/start-live-stream.sh"
        exit 0
    fi

    remaining=$(( deadline - now ))
    (( remaining < POLL )) && sleep "$remaining" || sleep "$POLL"
done
