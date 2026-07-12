#!/bin/bash
# Robust qpwgraph launcher for soundbooth
# Waits for graphical display (X11 or Wayland), then loads the saved patchbay
# in activated + exclusive mode.

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

exec /usr/bin/qpwgraph -a -x "${PATCHBAY}"
