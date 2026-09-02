#!/bin/bash
# Shared display helpers (XAUTHORITY / connector resolve for program output).
# Used by: start-ffmpeg-display, soundbooth-health, optional start-vlc (manual only).
# Name is legacy ("vlc-display"); VLC is not part of the AV pipeline.
# Do not execute directly.

# shellcheck disable=SC2034

soundbooth_load_vlc_conf() {
    local conf="${SOUNDBOOTH_VLC_CONF:-$HOME/.config/soundbooth/vlc-display.conf}"
    if [[ -f "$conf" ]]; then
        # shellcheck disable=SC1090
        source "$conf"
    fi
    PREFERRED_CONNECTOR="${VLC_OUTPUT_CONNECTOR:-DP-4}"
    VIDEO_DEV="${VLC_VIDEO_DEV:-/dev/video0}"
    GUARD_INTERVAL="${VLC_GUARD_INTERVAL_SEC:-20}"
    # Seconds to wait at boot for X auth + preferred connector (HDMI TVs lag)
    DISPLAY_WAIT_SEC="${VLC_DISPLAY_WAIT_SEC:-120}"
}

# GNOME Wayland: X11 clients need Mutter's Xwayland auth cookie, not just DISPLAY=:0.
# User systemd units often lack XAUTHORITY → xrandr empty → VLC falls on wrong screen.
soundbooth_export_display_env() {
    export DISPLAY="${DISPLAY:-:0}"
    export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"

    if [[ -n "${XAUTHORITY:-}" && -f "${XAUTHORITY}" ]]; then
        export XAUTHORITY
        return 0
    fi

    local uid auth
    uid=$(id -u)
    # Prefer live Mutter Xwayland auth (name is random per session)
    for auth in /run/user/"${uid}"/.mutter-Xwaylandauth.*; do
        if [[ -f "$auth" ]]; then
            export XAUTHORITY="$auth"
            return 0
        fi
    done
    if [[ -f "${HOME}/.Xauthority" ]]; then
        export XAUTHORITY="${HOME}/.Xauthority"
        return 0
    fi
    # Leave unset; callers wait/retry
    return 1
}

# True if we can talk to the X display and list at least one monitor
soundbooth_x_ready() {
    soundbooth_export_display_env || return 1
    local n
    n=$(xrandr --listmonitors 2>/dev/null | awk '/^Monitors:/{print $2; exit}')
    [[ -n "$n" && "$n" -ge 1 ]]
}

# True if preferred VLC connector (or a resolvable alternate) is present
soundbooth_preferred_connector_ready() {
    soundbooth_export_display_env || return 1
    local mon
    mon=$(soundbooth_resolve_vlc_monitor 2>/dev/null || true)
    [[ -n "$mon" ]]
}

# Block until preferred output is resolvable, or return 1 after timeout.
# Progress → stderr; on success prints one monitor line to stdout (INDEX CONN W H X Y)
# AND exports XAUTHORITY in the *current* shell.
#
# IMPORTANT: do NOT capture this with mon=$(soundbooth_wait_for_vlc_display) if you
# need XAUTHORITY afterward — command substitution runs in a subshell, so the export
# is lost and VLC launches without the Mutter cookie (lands on desktop / no Qt UI).
# Prefer soundbooth_wait_for_vlc_display_into VAR, or re-call soundbooth_export_display_env.
soundbooth_wait_for_vlc_display() {
    soundbooth_load_vlc_conf
    local max="${1:-$DISPLAY_WAIT_SEC}"
    local i mon
    echo "Waiting up to ${max}s for X auth + connector ${PREFERRED_CONNECTOR}..." >&2
    for i in $(seq 1 "$max"); do
        if soundbooth_export_display_env 2>/dev/null; then
            if mon=$(soundbooth_resolve_vlc_monitor 2>/dev/null) && [[ -n "$mon" ]]; then
                echo "Display ready after ${i}s (XAUTHORITY=${XAUTHORITY:-unset})" >&2
                echo "$mon"
                return 0
            fi
        fi
        sleep 1
    done
    echo "ERROR: preferred VLC output not ready after ${max}s (DISPLAY=${DISPLAY:-} XAUTHORITY=${XAUTHORITY:-unset})" >&2
    xrandr --listmonitors 2>&1 || true
    return 1
}

# Same wait as soundbooth_wait_for_vlc_display, but stores the monitor line in the
# named variable (nameref) so XAUTHORITY export stays in the caller's shell.
# Usage: soundbooth_wait_for_vlc_display_into MON || exit 1
soundbooth_wait_for_vlc_display_into() {
    local -n _soundbooth_mon_out="${1:?variable name required}"
    soundbooth_load_vlc_conf
    local max="${2:-$DISPLAY_WAIT_SEC}"
    local i mon
    echo "Waiting up to ${max}s for X auth + connector ${PREFERRED_CONNECTOR}..." >&2
    for i in $(seq 1 "$max"); do
        if soundbooth_export_display_env 2>/dev/null; then
            if mon=$(soundbooth_resolve_vlc_monitor 2>/dev/null) && [[ -n "$mon" ]]; then
                echo "Display ready after ${i}s (XAUTHORITY=${XAUTHORITY:-unset})" >&2
                _soundbooth_mon_out="$mon"
                return 0
            fi
        fi
        sleep 1
    done
    echo "ERROR: preferred VLC output not ready after ${max}s (DISPLAY=${DISPLAY:-} XAUTHORITY=${XAUTHORITY:-unset})" >&2
    xrandr --listmonitors 2>&1 || true
    return 1
}

# Print: INDEX CONNECTOR WIDTH HEIGHT X Y
# one line per monitor from xrandr --listmonitors
# Example: " 1: +DP-4 1920/800x1080/450+0+1080  DP-4"
soundbooth_list_monitors() {
    xrandr --listmonitors 2>/dev/null | awk '
        /^[[:space:]]*[0-9]+:/ {
            idx = $1
            gsub(/:/, "", idx)
            conn = $NF
            geom = ""
            for (i = 1; i <= NF; i++) {
                if (index($i, "/") && index($i, "x") && index($i, "+")) {
                    geom = $i
                    break
                }
            }
            if (geom == "") next
            # geom = 1920/800x1080/450+0+1080
            n = split(geom, parts, "+")
            if (n < 3) next
            x = parts[2]
            y = parts[3]
            split(parts[1], wh, "x")
            split(wh[1], wa, "/")
            split(wh[2], ha, "/")
            w = wa[1]
            h = ha[1]
            print idx, conn, w, h, x, y
        }
    '
}

# Resolve preferred monitor → prints: INDEX CONNECTOR W H X Y
soundbooth_resolve_vlc_monitor() {
    soundbooth_load_vlc_conf
    local pref="${1:-$PREFERRED_CONNECTOR}"
    local line

    if [[ -n "${VLC_SCREEN_NUMBER:-}" ]]; then
        line=$(soundbooth_list_monitors | awk -v i="$VLC_SCREEN_NUMBER" '$1==i {print; exit}')
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
    fi

    # 1) Exact connector match (DP-4)
    line=$(soundbooth_list_monitors | awk -v p="$pref" '$2==p {print; exit}')
    if [[ -n "$line" ]]; then
        echo "$line"
        return 0
    fi

    # 2) Known alternates
    local try
    for try in DP-4 HDMI-A-1 HDMI-1 HDMI-A-0; do
        line=$(soundbooth_list_monitors | awk -v p="$try" '$2==p {print; exit}')
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
    done

    # 3) Geometry heuristic: leftmost 1920x1080 (this booth: SII TV at +0+1080)
    line=$(soundbooth_list_monitors | awk '
        $3==1920 && $4==1080 {
            if (minx=="" || $5+0 < minx+0) { minx=$5; best=$0 }
        }
        END { if (best!="") print best }
    ')
    if [[ -n "$line" ]]; then
        echo "$line"
        return 0
    fi

    return 1
}

# VLC window origin X Y (best effort via xwininfo tree)
soundbooth_vlc_window_xy() {
    export DISPLAY="${DISPLAY:-:0}"
    xwininfo -root -tree 2>/dev/null | awk '
        /VLC media player/ && /\+[0-9]+\+[0-9]+/ {
            # last +X+Y on the line is root-relative for the frame
            n=split($0, parts, " ")
            for (i=n; i>=1; i--) {
                if (parts[i] ~ /^\+[0-9]+\+[0-9]+$/) {
                    split(parts[i], g, "+")
                    # g[1] empty, g[2]=x g[3]=y
                    print g[2], g[3]
                    exit
                }
            }
        }
    '
}

# Return 0 if VLC window is roughly on monitor rect (x,y,w,h)
soundbooth_vlc_on_monitor() {
    local mx="$1" my="$2" mw="$3" mh="$4"
    local xy wx wy
    xy=$(soundbooth_vlc_window_xy)
    [[ -z "$xy" ]] && return 1
    wx=$(echo "$xy" | awk '{print $1}')
    wy=$(echo "$xy" | awk '{print $2}')
    # Allow decoration / compositor offset (~80px)
    local cx cy
    cx=$((wx + 100))
    cy=$((wy + 100))
    if (( cx >= mx && cx < mx + mw && cy >= my && cy < my + mh )); then
        return 0
    fi
    return 1
}
