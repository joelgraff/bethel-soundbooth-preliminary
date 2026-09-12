#!/bin/bash
# End the Subsplash livestream NOW, without touching ATEM capture or the
# sanctuary TV. Cleanly closes the SRT connection so Subsplash ends the live
# event on their side immediately, instead of waiting out its 8-hour timeout.
#
# Safe to run any time: only stops ffmpeg-srt-relay.service. Capture, the
# DP-4 program display, and recording (if any) are unaffected.
#
# Resume: ~/bin/start-live-stream.sh

set -euo pipefail

echo "Stopping Subsplash livestream (ffmpeg-srt-relay.service)..."
systemctl --user stop ffmpeg-srt-relay.service
echo "Stream ended. Sanctuary TV and capture are still running."
echo "Resume with: ~/bin/start-live-stream.sh"
