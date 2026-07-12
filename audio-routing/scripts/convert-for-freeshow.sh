#!/bin/bash
# convert-for-freeshow.sh
# Convert webm (VP9) or other files to MP4/H.264 + AAC for smooth playback in FreeShow.
# Reason: This AMD GPU (Polaris/WX 3200) has no VP9 hardware decode. WebM stutters badly.
# MP4/H.264 plays smoothly with hardware acceleration.
#
# Usage:
#   convert-for-freeshow.sh input.webm
#   convert-for-freeshow.sh input.webm output.mp4
#
# Output will be placed next to the input (or specified) with .mp4 extension.
# Keeps reasonable quality for church projection.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <input.webm|input.mkv|...> [output.mp4]"
    exit 1
fi

INPUT="$1"
if [[ $# -ge 2 ]]; then
    OUTPUT="$2"
else
    BASENAME="${INPUT%.*}"
    OUTPUT="${BASENAME}.mp4"
fi

if [[ ! -f "$INPUT" ]]; then
    echo "Error: $INPUT not found"
    exit 1
fi

echo "Converting: $INPUT"
echo "       -> $OUTPUT"
echo "This uses H.264 + AAC (hardware friendly on this system)."

# Use libx264 (software encode, very reliable) + aac.
# CRF 23 is good quality. Preset medium for speed/quality balance.
# Audio: copy if possible, else aac 192k.
ffmpeg -hide_banner -loglevel warning -stats \
    -i "$INPUT" \
    -c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p \
    -c:a aac -b:a 192k \
    -movflags +faststart \
    "$OUTPUT"

echo ""
echo "Done: $OUTPUT"
echo "Test it in FreeShow. If still issues, try lowering -crf to 20 or use a two-pass."
echo "Tip for future yt-dlp downloads: yt-dlp -f 'bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]' ..."
