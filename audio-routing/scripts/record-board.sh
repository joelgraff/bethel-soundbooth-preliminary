#!/bin/bash
# record-board.sh — capture specific channels from the PreSonus 32SX's USB
# Send bus to a WAV file.
#
# Goes through raw ALSA (hw:3,0 at 64 channels), NOT PipeWire/Pulse — the
# PipeWire capture abstraction for this device silently reads all-zero on
# every channel even with confirmed real signal present (both the
# input:multichannel-input and pro-audio card profiles). See memory
# presonus_32sx_pipewire_capture_broken.md for the full diagnosis. Raw ALSA
# was confirmed 2026-09-04 to read real signal at exactly the channel
# numbers the board itself shows, and to coexist safely with
# presonus-foh-bridge.service's own raw ALSA playback on the same device
# (tested live, zero disruption to FOH audio).
#
# The hardware capture device is fixed at exactly 64 channels (not
# negotiable — confirmed via `arecord --dump-hw-params`), even though only
# channels 1-32 are meaningful (USB Sends 1-32 map 1:1 to board channels
# 1-32; the rest are typically silent/unused). Channel numbers below are
# 1-indexed to match the board's own channel numbering.
#
# Usage:
#   record-board.sh <channel[,channel...]> [output-name]
#   record-board.sh 17,18,19,20            # room mics -> 4-channel WAV
#   record-board.sh 21                     # single channel -> mono WAV
#   record-board.sh 17,18 monitor-check    # -> monitor-check.wav
#
# Output: ~/Recordings/<output-name-or-timestamp>.wav (24-bit PCM, 48kHz,
# channel order matches the order you listed them in).
# Stop with Ctrl-C — ffmpeg finalizes the WAV header cleanly on SIGINT.

set -euo pipefail

HW_DEVICE="${RECORD_BOARD_ALSA_DEVICE:-hw:3,0}"
HW_CHANNELS=64
OUT_DIR="${RECORD_BOARD_OUT_DIR:-${HOME}/Recordings}"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <channel[,channel...]> [output-name]" >&2
    echo "  e.g.: $0 17,18,19,20 room-mics" >&2
    exit 1
fi

CHANNELS_ARG="$1"
NAME="${2:-board-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT_DIR"
OUT_FILE="${OUT_DIR}/${NAME}.wav"

# Build the pan filter: "c0=cX|c1=cY|..." selecting 0-indexed raw channels
# in the order given, so e.g. "17,18,19,20" keeps that left-to-right order
# in the output file regardless of their position in the raw 64.
IFS=',' read -r -a CHANS <<< "$CHANNELS_ARG"
N=${#CHANS[@]}
PAN_TERMS=()
for i in "${!CHANS[@]}"; do
    ch="${CHANS[$i]}"
    if ! [[ "$ch" =~ ^[0-9]+$ ]] || (( ch < 1 || ch > HW_CHANNELS )); then
        echo "ERROR: channel '$ch' out of range 1-${HW_CHANNELS}" >&2
        exit 1
    fi
    raw_idx=$((ch - 1))
    PAN_TERMS+=("c${i}=c${raw_idx}")
done
PAN_FILTER="pan=${N}c|$(IFS='|'; echo "${PAN_TERMS[*]}")"

echo "Recording channel(s) ${CHANNELS_ARG} (board numbering) -> ${OUT_FILE}"
echo "Ctrl-C to stop."

# ffmpeg's ALSA input demuxer only exposes -sample_rate/-channels as
# options (see `ffmpeg -h demuxer=alsa`) — no way to force the S32_LE
# format this device requires (its only supported format; confirmed via
# `arecord --dump-hw-params`), and its own format auto-negotiation fails
# to open this device ("cannot set sample format ... Invalid argument").
# arecord opens it correctly, so it does the hardware capture; ffmpeg only
# does channel selection + WAV encoding on the resulting raw PCM stream —
# no ALSA negotiation on ffmpeg's side at all.
arecord -D "$HW_DEVICE" -f S32_LE -r 48000 -c "$HW_CHANNELS" -t raw 2>/dev/null | \
    exec ffmpeg -hide_banner -loglevel warning -stats \
        -f s32le -ar 48000 -ac "$HW_CHANNELS" -i pipe:0 \
        -filter_complex "$PAN_FILTER" \
        -c:a pcm_s24le \
        "$OUT_FILE"
