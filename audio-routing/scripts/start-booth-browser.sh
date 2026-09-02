#!/bin/bash
# Launch booth web browser (Vivaldi) on DP-1 ultrawide — never on program DP-4.
#
# Autostart: soundbooth-browser.desktop → this script
# Vivaldi/Chromium restore last window geometry and often reopen on DP-4.
# We force Chromium flags AND re-assert position with xdotool/wmctrl after map.

set -euo pipefail

# shellcheck disable=SC1091
if [[ -f "${HOME}/bin/vlc-display-lib.sh" ]]; then
    source "${HOME}/bin/vlc-display-lib.sh"
    soundbooth_export_display_env || true
fi
export DISPLAY="${DISPLAY:-:0}"

BOOTH_CONNECTOR="${SOUNDBOOTH_BROWSER_CONNECTOR:-DP-1}"
BROWSER="${SOUNDBOOTH_BROWSER:-/usr/bin/vivaldi-stable}"

geom_line=$(xrandr --query 2>/dev/null | awk -v c="$BOOTH_CONNECTOR" '
    $1 == c && / connected/ {
        for (i = 1; i <= NF; i++)
            if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) { print $i; exit }
    }')
if [[ -z "$geom_line" ]]; then
    echo "WARN: ${BOOTH_CONNECTOR} not found; launching browser without position" >&2
    exec "$BROWSER" "$@"
fi

W=${geom_line%%x*}
rest=${geom_line#*x}
H=${rest%%+*}
rest=${rest#*+}
X=${rest%%+*}
Y=${rest#*+}

WIN_W="${SOUNDBOOTH_BROWSER_W:-1400}"
WIN_H="${SOUNDBOOTH_BROWSER_H:-900}"
POS_X=$((X + 80))
POS_Y=$((Y + 80))

echo "Browser → ${BOOTH_CONNECTOR} target ${POS_X},${POS_Y} size ${WIN_W}x${WIN_H}"

# Background: keep shoving the window onto DP-1 for ~20s (session restore fights us)
(
    for _ in $(seq 1 40); do
        sleep 0.5
        # Prefer real content windows (skip 10x10 stubs)
        while read -r wid; do
            [[ -z "$wid" ]] && continue
            info=$(xwininfo -id "$wid" 2>/dev/null || true)
            w=$(echo "$info" | awk '/Width:/{print $2; exit}')
            h=$(echo "$info" | awk '/Height:/{print $2; exit}')
            [[ -n "$w" && -n "$h" ]] || continue
            if [[ "$w" -lt 200 || "$h" -lt 200 ]]; then
                continue
            fi
            if command -v xdotool >/dev/null 2>&1; then
                xdotool windowmove "$wid" "$POS_X" "$POS_Y" 2>/dev/null || true
                xdotool windowsize "$wid" "$WIN_W" "$WIN_H" 2>/dev/null || true
            fi
            if command -v wmctrl >/dev/null 2>&1; then
                wmctrl -i -r "$wid" -e "0,${POS_X},${POS_Y},${WIN_W},${WIN_H}" 2>/dev/null || true
            fi
        done < <(
            xdotool search --class 'Vivaldi' 2>/dev/null || true
            xdotool search --name 'Vivaldi' 2>/dev/null || true
            wmctrl -lx 2>/dev/null | awk '/[Vv]ivaldi/ {print $1}' || true
        )
    done
) &

exec "$BROWSER" \
    --window-position="${POS_X},${POS_Y}" \
    --window-size="${WIN_W},${WIN_H}" \
    "$@"
