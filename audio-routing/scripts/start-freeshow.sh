#!/bin/bash
# start-freeshow.sh
# Wrapper for FreeShow with tweaks for better media playback on this rig,
# plus force-placement of FreeShow's *main* window onto DP-1 (the booth's
# own monitor).
#
# WebM/VP9 often stutters because this GPU lacks VP9 hardware decode.
# Prefer MP4/H.264 files. This wrapper can be extended with Electron flags.
#
# Why force-placement: this booth's DP-2/DP-3/DP-4 are remote TVs elsewhere
# in the building that GNOME treats as valid, connected window targets even
# when nobody's looking at them or they're powered off — plus real dead
# space in the virtual desktop that isn't covered by any monitor at all. A
# freshly-launched window (FreeShow's main control window included) can land
# on one of those and simply be invisible to the operator. Same fix pattern
# as start-booth-browser.sh, adapted for FreeShow's main window only — the
# Primary/Stage *output* windows must stay on DP-2/DP-3, so we match on the
# exact title "FreeShow" (StartupWMClass=FreeShow), never a substring.

set -euo pipefail

# shellcheck disable=SC1091
if [[ -f "${HOME}/bin/vlc-display-lib.sh" ]]; then
    source "${HOME}/bin/vlc-display-lib.sh"
    soundbooth_export_display_env || true
fi
export DISPLAY="${DISPLAY:-:0}"

BOOTH_CONNECTOR="${SOUNDBOOTH_FREESHOW_CONNECTOR:-DP-1}"

geom_line=$(xrandr --query 2>/dev/null | awk -v c="$BOOTH_CONNECTOR" '
    $1 == c && / connected/ {
        for (i = 1; i <= NF; i++)
            if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) { print $i; exit }
    }')

if [[ -n "$geom_line" ]]; then
    W=${geom_line%%x*}
    rest=${geom_line#*x}
    H=${rest%%+*}
    rest=${rest#*+}
    X=${rest%%+*}
    Y=${rest#*+}

    WIN_W="${SOUNDBOOTH_FREESHOW_W:-1200}"
    WIN_H="${SOUNDBOOTH_FREESHOW_H:-900}"
    POS_X=$((X + 120))
    POS_Y=$((Y + 100))

    echo "FreeShow main window -> ${BOOTH_CONNECTOR} target ${POS_X},${POS_Y} size ${WIN_W}x${WIN_H}"

    # Background: re-assert position for ~20s after launch/window creation.
    # Matches the EXACT title "FreeShow" only — the Primary/Stage output
    # windows must never be moved off DP-2/DP-3.
    (
        for _ in $(seq 1 40); do
            sleep 0.5
            while read -r wid; do
                [[ -z "$wid" ]] && continue
                title=$(xdotool getwindowname "$wid" 2>/dev/null || true)
                [[ "$title" == "FreeShow" ]] || continue
                if command -v xdotool >/dev/null 2>&1; then
                    xdotool windowmove "$wid" "$POS_X" "$POS_Y" 2>/dev/null || true
                    xdotool windowsize "$wid" "$WIN_W" "$WIN_H" 2>/dev/null || true
                fi
                if command -v wmctrl >/dev/null 2>&1; then
                    wmctrl -i -r "$wid" -e "0,${POS_X},${POS_Y},${WIN_W},${WIN_H}" 2>/dev/null || true
                fi
            done < <(xdotool search --class 'FreeShow' 2>/dev/null || true)
        done
    ) &
else
    echo "WARN: ${BOOTH_CONNECTOR} not found; launching FreeShow without force-placement" >&2
fi

# Common Electron flags that sometimes help video on Linux
# (Vaapi may help H264/HEVC even if VP9 is software)
FLAGS=(
    --enable-features=VaapiVideoDecoder
    --use-gl=desktop
)

# If you want to force the deb version or AppImage, edit below.
# Currently uses whatever /usr/bin/freeshow points to.

echo "Launching FreeShow (with accel hints)..."

exec /usr/bin/freeshow "${FLAGS[@]}" "$@"
