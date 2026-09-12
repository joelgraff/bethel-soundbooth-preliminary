#!/bin/bash
# Low-fps JPEG preview capture for the dashboard's DP-4 (program) tile.
# Reads the ffmpeg-capture UDP encode tee — NOT ScreenCast: booth-multiview.py
# already found DP-4 ScreenCast damage-starved (~0-2fps, froze until a
# workspace switch), so this reuses the proven encode-tap approach instead.
#
# Uses the ":5002" free-probe port (see start-ffmpeg-capture.sh — "Optional
# free probe port for av-sync-calibrate, no default reader"). That port is
# exclusive (unicast, one reader): the dashboard backend stops this service
# before running an A/V sync calibration and restarts it after, so the two
# never actually fight over the port — see dashboard/backend/app/calibrate.py.
#
# Install: ~/bin/start-hdmi-preview-dp4.sh + hdmi-preview-dp4.service (user)

set -euo pipefail

OUT_DIR="${HDMI_PREVIEW_DIR:-/dev/shm/soundbooth-dashboard}"
OUT_FILE="${OUT_DIR}/dp4.jpg"
UDP_URL="${HDMI_PREVIEW_DP4_UDP:-udp://127.0.0.1:5002?fifo_size=5000000&overrun_nonfatal=1&timeout=0}"
# One frame every ~2s — a glance tile, not a video wall.
FPS="${HDMI_PREVIEW_DP4_FPS:-0.5}"
WIDTH="${HDMI_PREVIEW_WIDTH:-640}"
HEIGHT="${HDMI_PREVIEW_HEIGHT:-360}"

mkdir -p "$OUT_DIR"

echo "hdmi-preview-dp4: capturing ${UDP_URL} -> ${OUT_FILE} @ ${FPS}fps"

# Mid-stream MPEG-TS join needs a large probe (same reasoning as
# booth-multiview's encode feeder and av-sync-calibrate's capture_udp) or it
# fails to latch SPS/PPS and produces nothing.
exec /usr/bin/ffmpeg \
    -hide_banner -loglevel warning \
    -fflags +genpts+discardcorrupt \
    -analyzeduration 5000000 -probesize 5000000 \
    -i "$UDP_URL" \
    -an \
    -vf "fps=${FPS},scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2" \
    -update 1 -y \
    "$OUT_FILE"
