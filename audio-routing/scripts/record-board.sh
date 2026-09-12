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
#   record-board.sh [--split] <channel[,channel...]> [output-name]
#   record-board.sh 17,18,19,20            # room mics -> one 4-channel WAV
#   record-board.sh --split 17,18,19,20    # -> 4 separate mono WAVs
#   record-board.sh 21                     # single channel -> mono WAV
#   record-board.sh 17,18 monitor-check    # -> monitor-check.wav
#
# Output (no --split): ~/Recordings/<name-or-timestamp>.wav — one
# multichannel WAV, channel order matches the order you listed them in.
# Output (--split): ~/Recordings/<name-or-timestamp>-ch<N>.wav per channel —
# one mono WAV each, named by board channel number.
# Stop with Ctrl-C — ffmpeg finalizes the WAV header(s) cleanly on SIGINT.

set -euo pipefail

HW_DEVICE="${RECORD_BOARD_ALSA_DEVICE:-hw:3,0}"
HW_CHANNELS=64
OUT_DIR="${RECORD_BOARD_OUT_DIR:-${HOME}/Recordings}"

SPLIT=false
if [[ "${1:-}" == "--split" ]]; then
    SPLIT=true
    shift
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [--split] <channel[,channel...]> [output-name]" >&2
    echo "  e.g.: $0 17,18,19,20 room-mics" >&2
    echo "        $0 --split 17,18,19,20 room-mics" >&2
    exit 1
fi

CHANNELS_ARG="$1"
NAME="${2:-board-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT_DIR"

IFS=',' read -r -a CHANS <<< "$CHANNELS_ARG"
N=${#CHANS[@]}
for ch in "${CHANS[@]}"; do
    if ! [[ "$ch" =~ ^[0-9]+$ ]] || (( ch < 1 || ch > HW_CHANNELS )); then
        echo "ERROR: channel '$ch' out of range 1-${HW_CHANNELS}" >&2
        exit 1
    fi
done

# ffmpeg's ALSA input demuxer only exposes -sample_rate/-channels as
# options (see `ffmpeg -h demuxer=alsa`) — no way to force the S32_LE
# format this device requires (its only supported format; confirmed via
# `arecord --dump-hw-params`), and its own format auto-negotiation fails
# to open this device ("cannot set sample format ... Invalid argument").
# arecord opens it correctly, so it does the hardware capture; ffmpeg only
# does channel selection + WAV encoding on the resulting raw PCM stream —
# no ALSA negotiation on ffmpeg's side at all.

if ! $SPLIT; then
    OUT_FILE="${OUT_DIR}/${NAME}.wav"
    # "c0=cX|c1=cY|..." selecting 0-indexed raw channels in the order
    # given, so e.g. "17,18,19,20" keeps that left-to-right order in the
    # output file regardless of their position in the raw 64.
    PAN_TERMS=()
    for i in "${!CHANS[@]}"; do
        PAN_TERMS+=("c${i}=c$((CHANS[i] - 1))")
    done
    PAN_FILTER="pan=${N}c|$(IFS='|'; echo "${PAN_TERMS[*]}")"

    echo "Recording channel(s) ${CHANNELS_ARG} (board numbering) -> ${OUT_FILE}"
    echo "Ctrl-C to stop."
    arecord -D "$HW_DEVICE" -f S32_LE -r 48000 -c "$HW_CHANNELS" -t raw 2>/dev/null | \
        exec ffmpeg -hide_banner -loglevel warning -stats \
            -f s32le -ar 48000 -ac "$HW_CHANNELS" -i pipe:0 \
            -filter_complex "$PAN_FILTER" \
            -c:a pcm_s24le \
            "$OUT_FILE"
else
    # One arecord (the device only supports one reader) feeding one ffmpeg
    # process that splits the stream N ways internally (asplit) and writes
    # N separate mono files — not N separate arecord/ffmpeg pairs.
    SPLIT_TERMS=()
    PAN_BLOCKS=()
    MAP_ARGS=()
    OUT_FILES=()
    for i in "${!CHANS[@]}"; do
        ch="${CHANS[$i]}"
        SPLIT_TERMS+=("[s${i}]")
        PAN_BLOCKS+=("[s${i}]pan=mono|c0=c$((ch - 1))[o${i}]")
        MAP_ARGS+=(-map "[o${i}]" -c:a pcm_s24le "${OUT_DIR}/${NAME}-ch${ch}.wav")
        OUT_FILES+=("${NAME}-ch${ch}.wav")
    done
    FILTER="asplit=${N}$(IFS=''; echo "${SPLIT_TERMS[*]}");$(IFS=';'; echo "${PAN_BLOCKS[*]}")"

    echo "Recording channel(s) ${CHANNELS_ARG} (board numbering) -> ${OUT_FILES[*]/#/${OUT_DIR}/}"
    echo "Ctrl-C to stop."
    arecord -D "$HW_DEVICE" -f S32_LE -r 48000 -c "$HW_CHANNELS" -t raw 2>/dev/null | \
        exec ffmpeg -hide_banner -loglevel warning -stats \
            -f s32le -ar 48000 -ac "$HW_CHANNELS" -i pipe:0 \
            -filter_complex "$FILTER" \
            "${MAP_ARGS[@]}"
fi
