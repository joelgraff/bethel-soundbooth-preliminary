#!/usr/bin/env bash
# soundbooth-watch-lib.sh — shared helpers for this project's *-watch.sh
# restart-rate-limiting watchdogs (camera-management-watch.sh,
# ffmpeg-capture-watch.sh, ffmpeg-srt-watch.sh, presonus-usb-watch.sh).
#
# Extracted because count_restarts_last_hour()/record_restart() were
# byte-identical, independently copy-pasted into all four scripts — a real
# fix to the counting/pruning mechanics would otherwise need to be
# hand-ported to each one. Each script's own do_restart() — its debounce
# wording, which unit it restarts, any extra guard clauses (e.g.
# ffmpeg-srt-watch.sh's "don't restart an intentionally-stopped relay") —
# stays in the script itself; only the genuinely identical log-file
# mechanics moved here.
#
# Not meant to be run directly — source it, then call with an explicit log
# file path. Deliberately no shared global state: each caller still owns its
# own RESTART_LOG variable and passes it in explicitly, so there's no
# naming convention to get wrong between a script and this library.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/soundbooth-watch-lib.sh"
#   count_restarts_last_hour "$RESTART_LOG"   # -> prints a count to stdout
#   record_restart "$RESTART_LOG"             # appends now; prunes if log > 200 lines

count_restarts_last_hour() {  # log_path
    local log_path="$1" cutoff now
    now=$(date +%s)
    cutoff=$((now - 3600))
    [[ -f "$log_path" ]] || { echo 0; return; }
    awk -v c="$cutoff" '$1 >= c { n++ } END { print n+0 }' "$log_path"
}

record_restart() {  # log_path
    local log_path="$1"
    date +%s >> "$log_path"
    if [[ -f "$log_path" ]] && [[ "$(wc -l < "$log_path")" -gt 200 ]]; then
        tail -n 100 "$log_path" > "${log_path}.tmp" && mv "${log_path}.tmp" "$log_path"
    fi
}
