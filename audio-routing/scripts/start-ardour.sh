#!/bin/bash
# Robust Ardour launcher - native PipeWire + PreSonus wait + notification

set -euo pipefail

echo "=== Ardour starting at $(date) ==="

# Wait for graphical display
for i in {1..30}; do
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        echo "Display ready: ${DISPLAY:-$WAYLAND_DISPLAY}"
        break
    fi
    sleep 1
done

# Wait for PreSonus 32SX
echo "Waiting for PreSonus StudioLive 32SX..."
for i in {1..60}; do
    if pactl list short sources | grep -q "PreSonus_StudioLive_32SX"; then
        echo "PreSonus detected!"
        break
    fi
    sleep 2
done

# Create daily session
DATE=$(date +%Y%m%d_%H%M)
SESSION_NAME="Live_${DATE}"
SESSION_DIR="$HOME/Ardour/${SESSION_NAME}"
mkdir -p "${SESSION_DIR}"

echo "Launching Ardour session: ${SESSION_NAME}"

# Native PipeWire launch (no pw-jack)
exec ardour \
    -N "${SESSION_DIR}/${SESSION_NAME}.ardour" \
    -T "StudioLive_Session" &

# Give Ardour time to start, then show notification
sleep 8
notify-send "✅ PreSonus Audio Ready" \
    "Ardour started in native PipeWire mode\nMixer should now be visible in qpwgraph" \
    --icon=ardour --urgency=normal
