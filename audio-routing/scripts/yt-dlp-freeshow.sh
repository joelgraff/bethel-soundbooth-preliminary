#!/bin/bash
# yt-dlp-freeshow.sh — download video in FreeShow-friendly MP4/H.264 when possible
#
# Usage:
#   yt-dlp-freeshow.sh "https://youtube.com/watch?v=..."
#   yt-dlp-freeshow.sh -o "%(title)s.%(ext)s" URL
#
# Prefers mp4/m4a so VAAPI H.264 decode works on the WX 3200.
# Falls back to best available, then reminds to run convert-for-freeshow if needed.

set -euo pipefail

if ! command -v yt-dlp >/dev/null 2>&1; then
    # common local path from prior downloads on this machine
    for candidate in \
        "$HOME/Downloads/yt-dlp_linux" \
        "$HOME/Downloads/yt-dlp_linux (2)/yt-dlp_linux" \
        "$HOME/bin/yt-dlp"; do
        if [[ -x "$candidate" ]]; then
            PATH="$(dirname "$candidate"):$PATH"
            break
        fi
    done
fi

if ! command -v yt-dlp >/dev/null 2>&1; then
    echo "yt-dlp not found. Install it or put the binary on PATH." >&2
    exit 1
fi

# Default output into Downloads unless -o already provided
EXTRA=()
has_o=false
for a in "$@"; do
    [[ "$a" == "-o" || "$a" == --output || "$a" == --output=* ]] && has_o=true
done
if [[ "$has_o" != true ]]; then
    EXTRA+=(-o "$HOME/Downloads/%(title)s [%(id)s].%(ext)s")
fi

exec yt-dlp \
    -f 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best' \
    --merge-output-format mp4 \
    "${EXTRA[@]}" \
    "$@"
