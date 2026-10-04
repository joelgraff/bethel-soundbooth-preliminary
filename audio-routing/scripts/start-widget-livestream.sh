#!/bin/bash
# Launch the "Livestream" cockpit widget (start/stop + DP output tiles, no
# other dashboard chrome) in its own small Vivaldi window on DP-1.
# See docs/dp1-desktop-cockpit-plan.md — first widget of the DP-1 cockpit
# column; zone geometry/tiling assignment is still being tuned, so this
# script is manual-launch only for now (not wired into autostart).
#
# Modeled on start-booth-dashboard-view.sh: own profile (independent PIN
# session), same LOCAL_TOKEN auto-login bootstrap. Default position/size is
# a rough placeholder for the eventual DP-1 widget column, not a final
# tiling assignment.
#
# Runs under --ozone-platform=x11 (XWayland) rather than Vivaldi's native
# Wayland default, and strips its own titlebar/close button on launch, so it
# reads as a fixed cockpit panel rather than a browser window (confirmed
# live 2026-10-04: Mutter honors a live _MOTIF_WM_HINTS change on an XWayland
# window with no relaunch needed). This also means standard X11 tools
# (xdotool/xprop/import) can see and manipulate it, unlike a native-Wayland
# Vivaldi window. No close button after that - use
# `widget-window-ctl.sh SoundboothWidgetLivestream decorate` to get the
# titlebar back (e.g. to drag/resize/close by hand), or `... close` to just
# close it.

set -euo pipefail

# shellcheck disable=SC1091
if [[ -f "${HOME}/bin/vlc-display-lib.sh" ]]; then
    source "${HOME}/bin/vlc-display-lib.sh"
    soundbooth_export_display_env || true
fi
export DISPLAY="${DISPLAY:-:0}"

BOOTH_CONNECTOR="${SOUNDBOOTH_WIDGET_CONNECTOR:-DP-1}"
BROWSER="${SOUNDBOOTH_BROWSER:-/usr/bin/vivaldi-stable}"
BASE_URL="${SOUNDBOOTH_DASHBOARD_URL:-http://127.0.0.1:8420/widget-livestream.html}"
PROFILE_DIR="${SOUNDBOOTH_WIDGET_PROFILE:-${HOME}/.config/vivaldi-widget-livestream}"
DASHBOARD_CONF="${SOUNDBOOTH_DASHBOARD_CONF:-${HOME}/.config/soundbooth/dashboard.conf}"
WIDGET_CLASS="SoundboothWidgetLivestream"
CTL="${HOME}/bin/widget-window-ctl.sh"

LOCAL_TOKEN=""
if [[ -f "$DASHBOARD_CONF" ]]; then
    LOCAL_TOKEN=$(grep -E '^LOCAL_TOKEN=' "$DASHBOARD_CONF" | tail -1 | cut -d= -f2- | tr -d '"'"'"'')
fi

WIDGET_URL="$BASE_URL"
if [[ -n "$LOCAL_TOKEN" ]]; then
    SEP="?"
    [[ "$BASE_URL" == *\?* ]] && SEP="&"
    WIDGET_URL="${BASE_URL}${SEP}local_token=${LOCAL_TOKEN}"
else
    echo "WARN: no LOCAL_TOKEN in ${DASHBOARD_CONF} — will show the PIN screen" >&2
fi

WIN_W="${SOUNDBOOTH_WIDGET_W:-460}"
WIN_H="${SOUNDBOOTH_WIDGET_H:-900}"

# GNOME's top bar on this box isn't visible to EWMH _NET_WORKAREA (it reports
# the full virtual desktop, no panel reserved - confirmed 2026-10-04, likely
# because the bar is Shell/Wayland-native UI, not an X11 panel with strut
# hints) so positioning can't be computed from that. Empirically matched
# instead: other DP-1 windows placed by Mutter's normal (decorated) placement
# logic - FreeShow, Spotify - land with their frame top at monitor-Y + 28px.
# Used as the top-clearance margin below. If the booth's panel height/theme
# ever changes, override via SOUNDBOOTH_WIDGET_TOP_MARGIN rather than editing
# this default blind - re-derive it from a currently-correct window's Y, not
# by guessing.
TOP_PANEL_MARGIN="${SOUNDBOOTH_WIDGET_TOP_MARGIN:-28}"

# Poll for the window (it's not mapped the instant the browser process
# starts) and strip its titlebar/close button once found. Backgrounded so it
# doesn't delay the browser launch; harmless no-op if $CTL isn't installed
# yet (e.g. running straight from a repo checkout before an install pass).
#
# Keeps reasserting undecorate+move for a while *after* the first success,
# rather than trusting it and stopping there. Confirmed 2026-10-04: Mutter
# can re-wrap the window in a decorated frame on its own, after our hint was
# already applied once - observed while Chromium was still finishing startup
# (GPU/vsync errors logged around the same time), so it looks like some
# later internal map/configure event during that settling window makes
# Mutter re-evaluate decoration and get it wrong, not a one-shot race at
# first-map. No confirmed root cause; reasserting repeatedly sidesteps it
# without needing one. Same philosophy as vlc-display-lib.sh's
# same-value-twice debounce for the DP-4 boot race - don't trust a single
# good read during a window's startup settling period.
undecorate_when_ready() {
    local pos_x="${1:-}" pos_y="${2:-}"
    [[ -x "$CTL" ]] || return 0
    local got_one=0
    for _ in $(seq 1 20); do
        if "$CTL" "$WIDGET_CLASS" undecorate 2>/dev/null; then
            got_one=1
            break
        fi
        sleep 0.5
    done
    if [[ "$got_one" -ne 1 ]]; then
        echo "WARN: widget window never appeared for undecorate" >&2
        return 1
    fi
    # Reassert for ~8s in case Mutter re-decorates during Chromium's own
    # startup settling (observed, not just theoretical - see above).
    for _ in $(seq 1 8); do
        sleep 1
        "$CTL" "$WIDGET_CLASS" undecorate 2>/dev/null || true
        if [[ -n "$pos_x" && -n "$pos_y" ]]; then
            "$CTL" "$WIDGET_CLASS" move "$pos_x" "$pos_y" 2>/dev/null || true
        fi
    done
}

geom_line=$(xrandr --query 2>/dev/null | awk -v c="$BOOTH_CONNECTOR" '
    $1 == c && / connected/ {
        for (i = 1; i <= NF; i++)
            if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) { print $i; exit }
    }')
if [[ -z "$geom_line" ]]; then
    echo "WARN: ${BOOTH_CONNECTOR} not found; launching widget without position" >&2
    "$BROWSER" \
        --ozone-platform=x11 \
        --app="${WIDGET_URL}" \
        --user-data-dir="${PROFILE_DIR}" \
        --class="${WIDGET_CLASS}" \
        --window-size="${WIN_W},${WIN_H}" \
        --password-store=basic \
        "$@" &
    BROWSER_PID=$!
    undecorate_when_ready &
    disown
    wait "$BROWSER_PID"
    exit $?
fi

W=${geom_line%%x*}
rest=${geom_line#*x}
H=${rest%%+*}
rest=${rest#*+}
X=${rest%%+*}
Y=${rest#*+}

# Placeholder placement: right edge of the connector, top-aligned (below the
# panel). Final position is a tiling-zone decision, not this script's job.
POS_X=$((X + W - WIN_W))
POS_Y=$((Y + TOP_PANEL_MARGIN))

echo "Livestream widget -> ${BOOTH_CONNECTOR} target ${POS_X},${POS_Y} size ${WIN_W}x${WIN_H}"

"$BROWSER" \
    --ozone-platform=x11 \
    --app="${WIDGET_URL}" \
    --user-data-dir="${PROFILE_DIR}" \
    --class="${WIDGET_CLASS}" \
    --window-position="${POS_X},${POS_Y}" \
    --window-size="${WIN_W},${WIN_H}" \
    --password-store=basic \
    "$@" &
BROWSER_PID=$!
undecorate_when_ready "$POS_X" "$POS_Y" &
disown
wait "$BROWSER_PID"
