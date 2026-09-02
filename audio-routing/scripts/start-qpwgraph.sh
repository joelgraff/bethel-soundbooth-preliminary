#!/bin/bash
# Robust qpwgraph launcher for soundbooth
# Waits for graphical display (X11 or Wayland), then loads the saved patchbay
# in activate-only mode (-a). Never use exclusive (-x).

set -euo pipefail

echo "=== qpwgraph starting at $(date) ==="

# Wait for graphical display (supports both X11 and Wayland)
echo "Waiting for display..."
for i in {1..30}; do
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        echo "Display ready: ${DISPLAY:-$WAYLAND_DISPLAY}"
        break
    fi
    sleep 1
done

# Give the session a moment to stabilize (helps with Qt platform plugins)
sleep 2

# Prefer the correct Qt platform plugin
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-wayland}
else
    export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-xcb}
fi

echo "Using QT_QPA_PLATFORM=${QT_QPA_PLATFORM}"

PATCHBAY="/home/soundbooth/patchbay_profile/soundbooth.qpwgraph"

echo "Loading patchbay: ${PATCHBAY}"

# -a = activate patchbay links on start
# Do NOT use -x (exclusive): exclusive mode disconnects any link not listed in
# the patchbay file. Dynamic apps (Spotify, browsers, FreeShow) appear/disappear
# and exclusive mode caused intermittent silence after brief audio.
# Infrastructure: Mixer→Presonus (required), Spotify→Mixer (optional aid).
# ensure-audio-routes.service re-asserts Mixer→board after boot if activate misses.
exec /usr/bin/qpwgraph -a "${PATCHBAY}"
