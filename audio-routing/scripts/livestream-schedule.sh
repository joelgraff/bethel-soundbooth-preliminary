#!/usr/bin/env bash
# Show or change the recurring auto-start schedule for the Subsplash livestream.
#
# The livestream leg is NOT started at boot (see SYSTEM-STATE.md). This manages
# livestream-autostart.timer, which is the scheduled path; manual start/stop
# stays ~/bin/start-live-stream.sh and ~/bin/stop-live-stream.sh.
#
# Usage:
#   livestream-schedule.sh                     show schedule + next run
#   livestream-schedule.sh --set "Sun 09:23"   set a recurring day/time
#   livestream-schedule.sh --clear             revert to the shipped default
#   livestream-schedule.sh --enable            arm the schedule
#   livestream-schedule.sh --disable           disarm it (manual start only)
#
# The spec is a systemd calendar expression, so these all work:
#   "Sun 09:23"            every Sunday at 09:23
#   "Sun,Wed 18:30"        Sundays and Wednesdays at 18:30
#   "Sun 09:23,17:00"      twice on Sundays
# Validate anything unfamiliar with: systemd-analyze calendar "<spec>"

set -euo pipefail

TIMER="livestream-autostart.timer"
DROPIN_DIR="${HOME}/.config/systemd/user/${TIMER}.d"
DROPIN="${DROPIN_DIR}/schedule.conf"

usage() { sed -n '2,25p' "$0"; exit "${1:-0}"; }

# Always read state via `show -p`, never `is-active`/`is-enabled`: those print
# the state to stdout *and* exit non-zero for the inactive/disabled case, so the
# obvious `$(is-active || echo inactive)` idiom prints it twice.
prop() { systemctl --user show -p "$1" --value "$2" 2>/dev/null; }

show() {
    local enabled active spec next
    enabled="$(prop UnitFileState "$TIMER")"
    active="$(prop ActiveState "$TIMER")"

    echo "Livestream auto-start schedule"
    echo "  timer:     ${TIMER}  (${enabled:-not installed}, ${active:-unknown})"

    # Effective schedule, after any drop-in — not the shipped unit's line.
    # TimersCalendar looks like "{ OnCalendar=Sun *-*-* 09:23:00 ; next_elapse=... }",
    # one group per OnCalendar entry, so pull out just the specs.
    spec="$(prop TimersCalendar "$TIMER" \
            | grep -oE 'OnCalendar=[^;}]*' \
            | sed -e 's/^OnCalendar=//' -e 's/[[:space:]]*$//' \
            | paste -sd'; ' -)"
    echo "  schedule:  ${spec:-(none set)}"

    # On this systemd, NextElapseUSecRealtime --value is already a formatted
    # local-time string, not microseconds — print it as-is.
    next="$(prop NextElapseUSecRealtime "$TIMER")"
    if [[ -n "$next" && "$next" != "0" ]]; then
        echo "  next run:  ${next}"
    else
        echo "  next run:  never — schedule is not armed (--enable to arm)"
    fi

    [[ -f "$DROPIN" ]] && echo "  override:  ${DROPIN}"

    echo "  stream is: $(prop ActiveState ffmpeg-srt-relay.service)"
    echo
    echo "Manual control: ~/bin/start-live-stream.sh | ~/bin/stop-live-stream.sh"
}

set_schedule() {
    local spec="$1"
    [[ -n "${spec// }" ]] || { echo "ERROR: empty schedule spec" >&2; exit 1; }

    if ! systemd-analyze calendar "$spec" >/dev/null 2>&1; then
        echo "ERROR: '${spec}' is not a valid systemd calendar spec." >&2
        echo "  Try: systemd-analyze calendar \"${spec}\"" >&2
        exit 1
    fi

    mkdir -p "$DROPIN_DIR"
    # The bare "OnCalendar=" first is REQUIRED: systemd *accumulates* OnCalendar
    # entries across a unit and its drop-ins, so without the reset the old
    # schedule would keep firing alongside the new one.
    cat > "$DROPIN" <<EOF
# Written by livestream-schedule.sh — edit via that script, not by hand.
[Timer]
OnCalendar=
OnCalendar=${spec}
EOF

    systemctl --user daemon-reload
    # Only bounce the timer if it's meant to be running; don't silently arm a
    # schedule the operator had deliberately disabled.
    if systemctl --user is-enabled --quiet "$TIMER" 2>/dev/null; then
        systemctl --user restart "$TIMER"
    fi

    echo "Schedule set to: ${spec}"
    echo
    show
}

clear_schedule() {
    if [[ -f "$DROPIN" ]]; then
        rm -f "$DROPIN"
        rmdir "$DROPIN_DIR" 2>/dev/null || true
        systemctl --user daemon-reload
        systemctl --user is-enabled --quiet "$TIMER" 2>/dev/null && systemctl --user restart "$TIMER"
        echo "Override removed — back to the shipped default."
    else
        echo "No override in place; already on the shipped default."
    fi
    echo
    show
}

case "${1:-}" in
    "")            show ;;
    --set)         [[ $# -ge 2 ]] || usage 1; set_schedule "$2" ;;
    --clear)       clear_schedule ;;
    --enable)      systemctl --user enable --now "$TIMER"; echo "Schedule armed."; echo; show ;;
    --disable)     systemctl --user disable --now "$TIMER"; echo "Schedule disarmed — manual start only."; echo; show ;;
    -h|--help)     usage 0 ;;
    *)             echo "ERROR: unknown argument '$1'" >&2; usage 1 ;;
esac
