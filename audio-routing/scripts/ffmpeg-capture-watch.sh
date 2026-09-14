#!/bin/bash
# Watch ffmpeg-capture.service for "process alive but not actually encoding"
# — Restart=always only catches a hard crash/exit, not a stall. This is the
# single highest-leverage failure point in the pipeline: DP-4/back-TVs, both
# dashboard preview tiles, and the SRT relay to Subsplash all fan out from
# this one process's tee, so a silent stall here takes everything dark at
# once (see STATUS.md 2026-09-04 for the "alive but wrong" pattern this
# project has hit repeatedly — CMP not binding its port, ffplay mispositioned,
# the 32SX not clock-locked — all "active" the whole time by systemd's own
# reckoning).
#
# Check used: real capture/encode work is CPU-heavy (soundbooth-health.sh
# expects ~88-96% on this process). Sample the process's own CPU ticks
# (/proc/<pid>/stat utime+stime) across one poll interval — if it's doing
# real work, CPU usage stays high; if the v4l2 read or encode loop is wedged
# waiting forever, CPU drops near zero. Deliberately NOT tapping a UDP tee
# leg to check for frames: those ports are each already claimed by a single
# exclusive reader (ffplay/:5000, av-sync-calibrate+dashboard/:5002, SRT
# relay/:5003, livestream tile/:5001) — a low-CPU check needs no port at all
# and can't collide with any of them.
#
# Env (optional, conf or service Environment=):
#   FFMPEG_CAPTURE_WATCH_POLL_SEC        poll interval seconds (default 30)
#   FFMPEG_CAPTURE_WATCH_GRACE_SEC       grace after (re)start before acting (default 60)
#   FFMPEG_CAPTURE_WATCH_MIN_GAP_SEC     debounce between restarts (default 180)
#   FFMPEG_CAPTURE_WATCH_MAX_PER_HOUR    cap restarts (default 4)
#   FFMPEG_CAPTURE_WATCH_CPU_PCT_MIN     below this %CPU over one poll window = stalled (default 15)
#   FFMPEG_CAPTURE_WATCH_DISABLE=1       no-op loop (for testing)
#
# systemctl --user status ffmpeg-capture-watch.service

set -uo pipefail

POLL="${FFMPEG_CAPTURE_WATCH_POLL_SEC:-30}"
GRACE="${FFMPEG_CAPTURE_WATCH_GRACE_SEC:-60}"
MIN_GAP="${FFMPEG_CAPTURE_WATCH_MIN_GAP_SEC:-180}"
MAX_HOUR="${FFMPEG_CAPTURE_WATCH_MAX_PER_HOUR:-4}"
CPU_PCT_MIN="${FFMPEG_CAPTURE_WATCH_CPU_PCT_MIN:-15}"
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/soundbooth-ffmpeg-capture-watch"
mkdir -p "$STATE_DIR"
RESTART_LOG="${STATE_DIR}/restarts.log"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/soundbooth-watch-lib.sh"

log() { echo "[ffmpeg-capture-watch $(date +%H:%M:%S)] $*"; }

# utime+stime in clock ticks for a PID, or empty if it's gone.
cpu_ticks() {
    local pid="$1" stat
    stat=$(cat "/proc/${pid}/stat" 2>/dev/null) || return 1
    # Field 2 (comm) can contain spaces/parens — split after the last ')'.
    stat="${stat##*) }"
    # Now fields are 3.. of the original; utime=14th orig => 12th here, stime=15th orig => 13th here.
    read -r -a f <<< "$stat"
    local utime="${f[11]:-}" stime="${f[12]:-}"
    [[ -n "$utime" && -n "$stime" ]] || return 1
    echo $((utime + stime))
}

do_restart() {
    local reason="$1"
    local now n

    if [[ "${FFMPEG_CAPTURE_WATCH_DISABLE:-0}" == "1" ]]; then
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
            "Investigate manually: systemctl --user restart ffmpeg-capture"
        return
    fi

    log "ffmpeg-capture stalled (${reason}) — restarting [hour count $((n + 1))/${MAX_HOUR}]"
    if systemctl --user restart ffmpeg-capture.service; then
        LAST_RESTART=$now
        record_restart "$RESTART_LOG"
        log "restart issued OK"
    else
        log "ERROR: systemctl restart ffmpeg-capture failed"
    fi
}

log "watching ffmpeg-capture.service CPU activity (poll ${POLL}s, grace ${GRACE}s, min gap ${MIN_GAP}s, max ${MAX_HOUR}/h, floor ${CPU_PCT_MIN}%)"

while true; do
    sleep "$POLL"

    if ! systemctl --user is-active --quiet ffmpeg-capture.service 2>/dev/null; then
        # Not our problem — either intentionally stopped, or Restart=always
        # is already handling a process death.
        continue
    fi

    active_since=$(systemctl --user show ffmpeg-capture.service -p ActiveEnterTimestamp --value 2>/dev/null || true)
    if [[ -z "$active_since" || "$active_since" == "n/a" ]]; then
        continue
    fi
    active_since_ts=$(date -d "$active_since" +%s 2>/dev/null) || continue

    now=$(date +%s)
    age=$((now - active_since_ts))
    if (( age < GRACE )); then
        continue
    fi

    pid=$(systemctl --user show ffmpeg-capture.service -p MainPID --value 2>/dev/null || true)
    if [[ -z "$pid" || "$pid" == "0" ]]; then
        continue
    fi

    t1=$(cpu_ticks "$pid") || continue
    sleep 5
    # Re-check the service didn't stop/restart out from under us mid-sample.
    pid2=$(systemctl --user show ffmpeg-capture.service -p MainPID --value 2>/dev/null || true)
    [[ "$pid2" == "$pid" ]] || continue
    t2=$(cpu_ticks "$pid") || continue

    delta_ticks=$((t2 - t1))
    # %CPU over the 5s sample window.
    pct=$(awk -v d="$delta_ticks" -v tck="$CLK_TCK" 'BEGIN { printf "%.1f", (d / tck) / 5 * 100 }')

    if awk -v p="$pct" -v m="$CPU_PCT_MIN" 'BEGIN { exit !(p < m) }'; then
        do_restart "CPU ${pct}% < ${CPU_PCT_MIN}% floor, ${age}s after (re)start"
    fi
done
