#!/usr/bin/env bash
# Toggle window decorations (titlebar + close/minimize/maximize buttons) on,
# or close, one of the DP-1 cockpit widget windows (start-widget-livestream.sh
# and friends) by its WM_CLASS.
#
# Those widgets launch with --ozone-platform=x11 specifically so they land in
# the XWayland tree where xprop/xdotool can reach them - a native-Wayland
# Chromium window is invisible to these tools (see booth_gui_screenshot_method
# in project memory). Mutter honors a live _MOTIF_WM_HINTS change on an
# already-mapped XWayland window with no relaunch needed (confirmed
# 2026-10-04): decorations=0 drops its "mutter-x11-frames" wrapper
# immediately; decorations=1 restores it, titlebar/close button and all. This
# is the safety valve for a widget that normally runs undecorated (see
# start-widget-livestream.sh) - use it if one needs to be dragged, resized, or
# closed by hand instead of via systemctl/pkill.
#
# Usage:
#   widget-window-ctl.sh [CLASS] status        show decorated y/n + window id
#   widget-window-ctl.sh [CLASS] decorate      restore titlebar/close button
#   widget-window-ctl.sh [CLASS] undecorate    strip titlebar/close button
#   widget-window-ctl.sh [CLASS] close         close the window (clean)
#   widget-window-ctl.sh [CLASS] move X Y      reposition (absolute, root coords)
#
# CLASS defaults to SoundboothWidgetLivestream. ACTION defaults to status.
# move takes X Y as extra positional args after ACTION.

set -euo pipefail

CLASS="${1:-SoundboothWidgetLivestream}"
ACTION="${2:-status}"

export DISPLAY="${DISPLAY:-:0}"

usage() { sed -n '2,20p' "$0"; exit "${1:-0}"; }
[[ "$ACTION" =~ ^(decorate|undecorate|close|status|move)$ ]] || usage 1

# A WM_CLASS match alone is ambiguous: Chromium/Vivaldi also creates a tiny
# (10x10) hidden helper window carrying the same --class string as the real
# content window (confirmed 2026-10-04 - `head -1` on an unordered match set
# grabbed the helper once and silently no-op'd on the real window). Picking
# the largest-area match sidesteps that without depending on window title
# text, which the widget's own page controls and could change.
WID=""
BEST_AREA=-1
while read -r id; do
    [[ -z "$id" ]] && continue
    geom="$(xdotool getwindowgeometry --shell "$id" 2>/dev/null)" || continue
    w="$(awk -F= '/^WIDTH=/{print $2}' <<<"$geom")"
    h="$(awk -F= '/^HEIGHT=/{print $2}' <<<"$geom")"
    [[ -z "$w" || -z "$h" ]] && continue
    area=$((w * h))
    if (( area > BEST_AREA )); then
        BEST_AREA=$area
        WID=$id
    fi
done < <(xdotool search --class "$CLASS" 2>/dev/null)

if [[ -z "$WID" ]]; then
    echo "No window found for class '$CLASS' (is it running, and under --ozone-platform=x11?)" >&2
    exit 1
fi

case "$ACTION" in
    undecorate)
        xprop -id "$WID" -f _MOTIF_WM_HINTS 32c -set _MOTIF_WM_HINTS "0x2, 0x0, 0x0, 0x0, 0x0"
        echo "undecorated: $CLASS (window $WID)"
        ;;
    decorate)
        xprop -id "$WID" -f _MOTIF_WM_HINTS 32c -set _MOTIF_WM_HINTS "0x2, 0x0, 0x1, 0x0, 0x0"
        echo "decorated: $CLASS (window $WID) - titlebar/close button restored"
        ;;
    close)
        xdotool windowclose "$WID"
        echo "closed: $CLASS (window $WID)"
        ;;
    move)
        MOVE_X="${3:?usage: widget-window-ctl.sh CLASS move X Y}"
        MOVE_Y="${4:?usage: widget-window-ctl.sh CLASS move X Y}"
        xdotool windowmove --sync "$WID" "$MOVE_X" "$MOVE_Y"
        echo "moved: $CLASS (window $WID) -> ${MOVE_X},${MOVE_Y}"
        ;;
    status)
        echo "$CLASS -> window $WID"
        xprop -id "$WID" _MOTIF_WM_HINTS 2>/dev/null \
            || echo "(no _MOTIF_WM_HINTS property set - WM default, normally decorated)"
        ;;
esac
