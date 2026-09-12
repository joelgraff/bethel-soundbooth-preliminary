#!/bin/bash
# Low-fps JPEG preview capture for the dashboard's "Livestream" tile.
# Reads the ffmpeg-capture UDP encode tee — same technique as
# start-hdmi-preview-dp4.sh (see that file for why: ScreenCast on DP-4 was
# damage-starved, so this reuses the proven encode-tap approach).
#
# Uses the ":5001" free-preview port (see start-ffmpeg-capture.sh's
# LOCAL_UDP_PREVIEW — "created so a preview consumer doesn't fight ffplay on
# :5000"). Deliberately NOT :5003 — that port is the actual SRT relay's
# exclusive input leg (start-ffmpeg-srt-relay.sh); a second reader there
# would compete with the real broadcast to Subsplash for an exclusive
# unicast port. This tile shows the same encode the relay sends out, just
# via its own non-competing tap, not a literal read of the relay's output.
#
# Install: ~/bin/start-hdmi-preview-livestream.sh + hdmi-preview-livestream.service (user)

set -euo pipefail

OUT_DIR="${HDMI_PREVIEW_DIR:-/dev/shm/soundbooth-dashboard}"
OUT_FILE="${OUT_DIR}/livestream.jpg"
UDP_URL="${HDMI_PREVIEW_LIVESTREAM_UDP:-udp://127.0.0.1:5001?fifo_size=5000000&overrun_nonfatal=1&timeout=0}"
# One frame every ~2s — a glance tile, not a video wall.
FPS="${HDMI_PREVIEW_LIVESTREAM_FPS:-0.5}"
WIDTH="${HDMI_PREVIEW_WIDTH:-640}"
HEIGHT="${HDMI_PREVIEW_HEIGHT:-360}"

mkdir -p "$OUT_DIR"

echo "hdmi-preview-livestream: capturing ${UDP_URL} -> ${OUT_FILE} @ ${FPS}fps"

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
