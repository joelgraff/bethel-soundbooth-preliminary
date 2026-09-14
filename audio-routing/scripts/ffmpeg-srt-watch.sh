#!/usr/bin/env bash
# Watch ffmpeg-srt-relay for a hung SRT connection and restart it.
#
# Background (2026-08-23 split): ffmpeg-srt-relay.service is now a single-output
# process (local capture → SRT, stream copy, no tee). A dead SRT connection
# normally makes ffmpeg exit on its own, and systemd Restart=always already
# reconnects — this watcher is only a backup for the case where ffmpeg hangs
# without exiting (rare, but seen historically before the split).
#
# It only ever restarts ffmpeg-srt-relay.service — capture and the sanctuary
# TV display are on separate services and are never touched here.
#
# Env (optional, conf or service Environment=):
#   FFMPEG_SRT_WATCH_MIN_GAP_SEC     debounce between restarts (default 90)
#   FFMPEG_SRT_WATCH_MAX_PER_HOUR    cap restarts (default 8)
#   FFMPEG_SRT_WATCH_DISABLE=1       no-op loop (for testing)
#
# systemctl --user status ffmpeg-srt-watch.service

set -euo pipefail

MIN_GAP="${FFMPEG_SRT_WATCH_MIN_GAP_SEC:-90}"
MAX_HOUR="${FFMPEG_SRT_WATCH_MAX_PER_HOUR:-8}"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/soundbooth-ffmpeg-srt-watch"
mkdir -p "$STATE_DIR"
RESTART_LOG="${STATE_DIR}/restarts.log"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/soundbooth-watch-lib.sh"

log() { echo "[ffmpeg-srt-watch $(date +%H:%M:%S)] $*"; }

do_restart() {
    local reason="$1"
    local now n

    if [[ "${FFMPEG_SRT_WATCH_DISABLE:-0}" == "1" ]]; then
        log "DISABLE set — would restart for: $reason"
        return
    fi

    if ! systemctl --user is-active --quiet ffmpeg-srt-relay.service 2>/dev/null; then
        log "ffmpeg-srt-relay not active (stream likely ended intentionally) — skip restart ($reason)"
        return
    fi

    now=$(date +%s)
    if [[ -n "${LAST_RESTART:-}" ]] && (( now - LAST_RESTART < MIN_GAP )); then
        log "debounced (${MIN_GAP}s) — $reason"
        return
    fi

    n=$(count_restarts_last_hour "$RESTART_LOG")
    if (( n >= MAX_HOUR )); then
        log "MAX restarts/hour (${MAX_HOUR}) reached — NOT restarting ($reason). Fix network/Subsplash or: systemctl --user restart ffmpeg-srt-relay"
        return
    fi

    log "SRT hang/failure detected — restarting ffmpeg-srt-relay ($reason) [hour count $((n + 1))/${MAX_HOUR}]"
    if systemctl --user restart ffmpeg-srt-relay.service; then
        LAST_RESTART=$now
        record_restart "$RESTART_LOG"
        log "restart issued OK"
    else
        log "ERROR: systemctl restart ffmpeg-srt-relay failed"
    fi
}

log "watching journal for SRT relay failure/hang (min gap ${MIN_GAP}s, max ${MAX_HOUR}/h)"

# -n 0: only new lines (do not replay old failures on watch start)
# --output=cat so we see raw ffmpeg lines inside journal payloads
journalctl --user -u ffmpeg-srt-relay.service -f -n 0 --output=cat 2>/dev/null | while IFS= read -r line || [[ -n "$line" ]]; do
    # Progress lines use \r; journal may deliver chunks — normalize
    line="${line//$'\r'/ }"

    # Ignore orderly teardown (systemctl stop/restart) — not a livestream fault
    if [[ "$line" == *"Immediate exit requested"* ]] \
        || [[ "$line" == *"Exiting normally"* ]]; then
        continue
    fi

    # Explicit SRT write/path death after running
    if [[ "$line" =~ \[srt\ @ ]] && [[ "$line" =~ (Broken\ pipe|Connection\ reset|Connection\ timed\ out|End\ of\ file|Error) ]]; then
        do_restart "$line"
        continue
    fi
done
