#!/bin/bash
# Start booth multiview (Wayland-safe: Mutter ScreenCast + encode UDP).
# Places on GNOME workspace 2 via Auto Move Windows + desktop file association.
# See booth-multiview.py and configure-multiview-workspace.sh.
set -euo pipefail

# shellcheck disable=SC1091
if [[ -f "${HOME}/bin/vlc-display-lib.sh" ]]; then
    source "${HOME}/bin/vlc-display-lib.sh"
    soundbooth_export_display_env || true
fi
export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

SCRIPT="${HOME}/bin/booth-multiview.py"
if [[ ! -f "$SCRIPT" && -f "${HOME}/soundbooth-project/audio-routing/scripts/booth-multiview.py" ]]; then
    install -m 0755 "${HOME}/soundbooth-project/audio-routing/scripts/booth-multiview.py" "$SCRIPT"
fi
chmod +x "$SCRIPT" 2>/dev/null || true

# Ensure workspace config + desktop file (idempotent)
if [[ -x "${HOME}/bin/configure-multiview-workspace.sh" ]]; then
    "${HOME}/bin/configure-multiview-workspace.sh" >/dev/null 2>&1 || true
elif [[ -f "${HOME}/soundbooth-project/audio-routing/scripts/configure-multiview-workspace.sh" ]]; then
    bash "${HOME}/soundbooth-project/audio-routing/scripts/configure-multiview-workspace.sh" >/dev/null 2>&1 || true
fi

# Prefer gtk-launch so GNOME Shell maps the window to soundbooth-multiview.desktop
# (Auto Move Windows then sends it to workspace 2). Avoid re-entry when already launched.
DESKTOP_ID="soundbooth-multiview.desktop"
if [[ -z "${GIO_LAUNCHED_DESKTOP_FILE:-}" ]] \
    && [[ "${SOUNDBOOTH_MULTIVIEW_DIRECT:-0}" != "1" ]] \
    && command -v gtk-launch >/dev/null 2>&1 \
    && [[ -f "${HOME}/.local/share/applications/${DESKTOP_ID}" ]]; then
    # Stop previous before re-launch
    PIDFILE="${XDG_RUNTIME_DIR}/soundbooth-multiview/multiview.pid"
    if [[ -f "$PIDFILE" ]]; then
        old=$(cat "$PIDFILE" 2>/dev/null || true)
        if [[ -n "${old:-}" ]] && kill -0 "$old" 2>/dev/null; then
            kill "$old" 2>/dev/null || true
            sleep 0.5
        fi
        rm -f "$PIDFILE"
    fi
    echo "Starting multiview via gtk-launch (${DESKTOP_ID}) → workspace 2"
    # gtk-launch does not forward args; env still works
    export SOUNDBOOTH_MULTIVIEW_DIRECT=1
    exec gtk-launch soundbooth-multiview
fi

# Direct path (already gtk-launched, or no desktop file)
PIDFILE="${XDG_RUNTIME_DIR}/soundbooth-multiview/multiview.pid"
if [[ -f "$PIDFILE" ]]; then
    old=$(cat "$PIDFILE" 2>/dev/null || true)
    if [[ -n "${old:-}" ]] && kill -0 "$old" 2>/dev/null; then
        kill "$old" 2>/dev/null || true
        sleep 0.8
    fi
    rm -f "$PIDFILE"
fi

LOG="${XDG_RUNTIME_DIR}/soundbooth-multiview/multiview.log"
mkdir -p "$(dirname "$LOG")"
echo "Starting booth multiview (direct) → log $LOG"
exec "$SCRIPT" "$@" >>"$LOG" 2>&1
