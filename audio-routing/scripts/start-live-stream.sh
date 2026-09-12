#!/bin/bash
# (Re)start the Subsplash livestream leg (ffmpeg-srt-relay.service).
# Capture and the sanctuary TV run independently and don't need to be touched.

set -euo pipefail

if ! systemctl --user is-active --quiet ffmpeg-capture.service; then
    echo "WARNING: ffmpeg-capture.service is not active — starting it too." >&2
    systemctl --user start ffmpeg-capture.service
    sleep 2
fi

echo "Starting Subsplash livestream (ffmpeg-srt-relay.service)..."
systemctl --user start ffmpeg-srt-relay.service
echo "Started. Check: systemctl --user status ffmpeg-srt-relay.service"
echo "Verify on Subsplash: https://dashboard.subsplash.com/-d/#/media/live"
