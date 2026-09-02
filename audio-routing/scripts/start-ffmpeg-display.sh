#!/bin/bash
# Fullscreen program display on preferred connector (default DP-4) via ffplay.
# Reads local MPEG-TS from FFmpeg (UDP). Part of the FFmpeg livestream stack (no VLC).
#
# The DP-4 output feeds not just the sanctuary TV directly but also, downstream
# via a GoFanco HDMI-over-Cat splitter/extender, the back-of-house TVs. That
# extender path (or those TVs' own picture processing) adds video latency that
# ffmpeg-capture's shared FFMPEG_AUDIO_DELAY_SEC cannot compensate for, because
# that delay is baked into the one shared encode before ffmpeg-capture's tee
# splits out to the SRT relay (:5003) as well — raising it would desync the
# livestream to fix the back TVs. FFMPEG_TV_EXTRA_AUDIO_DELAY_SEC below adds an
# *additional* delay applied only on this display leg (confirmed 2026-08-30).
#
# Service: ffmpeg-display.service

set -euo pipefail

# shellcheck disable=SC1091
source "${HOME}/bin/vlc-display-lib.sh"
soundbooth_load_vlc_conf

CONF="${HOME}/.config/soundbooth/ffmpeg-srt.conf"
if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

# Prefer HTTP local feed from ffmpeg-capture (reconnect-friendly)
LOCAL_PLAY="${FFMPEG_LOCAL_PLAY:-udp://@127.0.0.1:5000}"
WINDOW_TITLE="${FFMPEG_WINDOW_TITLE:-Soundbooth Program}"

# Extra lip-sync delay for THIS leg only (back TVs / extender latency), on top
# of the shared FFMPEG_AUDIO_DELAY_SEC baked into ffmpeg-capture's encode.
# Does not touch the SRT relay — that reads ffmpeg-capture's :5003 tee directly.
TV_EXTRA_DELAY_SEC="${FFMPEG_TV_EXTRA_AUDIO_DELAY_SEC:-0}"
TV_DELAY_RELAY_UDP="${FFMPEG_LOCAL_UDP_TV_DELAYED:-udp://127.0.0.1:5010?pkt_size=1316}"
TV_DELAY_PID=""
soundbooth_export_display_env || true
MON=""
if ! soundbooth_wait_for_vlc_display_into MON; then
    echo "ERROR: preferred display not ready" >&2
    exit 1
fi
if ! soundbooth_export_display_env || [[ -z "${XAUTHORITY:-}" || ! -f "${XAUTHORITY}" ]]; then
    echo "ERROR: XAUTHORITY missing" >&2
    exit 1
fi
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY
export SDL_VIDEODRIVER=x11

CONN=$(echo "$MON" | awk '{print $2}')
W=$(echo "$MON" | awk '{print $3}')
H=$(echo "$MON" | awk '{print $4}')
X=$(echo "$MON" | awk '{print $5}')
Y=$(echo "$MON" | awk '{print $6}')

# Ensure GPU audio profile is normal stereo for HDMI TV (not pro-audio multi-PCM,
# which rejects ordinary Pulse sink-input moves and left audio on Mixer).
pactl set-card-profile alsa_card.pci-0000_07_00.1 output:hdmi-stereo-extra1 2>/dev/null || true
# hdmi-stereo-extra1 = HDMI TV (DP-4) on this machine
HDMI_SINK="${FFMPEG_HDMI_AUDIO_SINK:-}"
if [[ -z "$HDMI_SINK" ]]; then
    HDMI_SINK=$(pactl list short sinks 2>/dev/null | awk '/hdmi-stereo-extra1/ {print $2; exit}')
fi
[[ -n "$HDMI_SINK" ]] || HDMI_SINK=$(pactl list short sinks 2>/dev/null | awk '/hdmi-stereo/ {print $2; exit}')
[[ -n "$HDMI_SINK" ]] || HDMI_SINK=LocalLive

export SDL_AUDIODRIVER=pulse
export PULSE_SINK="${HDMI_SINK}"
export PIPEWIRE_NODE="${HDMI_SINK}"

echo "ffplay program display → ${CONN} ${W}x${H}+${X}+${Y}"
echo "source: ${LOCAL_PLAY}"
echo "audio sink: ${HDMI_SINK} (HDMI TV — not Mixer/FOH)"

# Wait for FFmpeg producer (UDP multicast needs no exclusive client)
for _ in $(seq 1 60); do
    if systemctl --user is-active --quiet ffmpeg-capture.service 2>/dev/null \
        && pgrep -x ffmpeg &>/dev/null; then
        echo "ffmpeg-capture ready"
        sleep 2
        break
    fi
    sleep 1
done

# If extra TV-leg delay is configured, insert a delay-relay stage: consume the
# raw capture feed, stream-copy video (cheap) and re-encode only audio with the
# additional adelay, then have ffplay read the relay's output instead of the
# raw feed. Leaves ffmpeg-capture and the SRT relay completely untouched.
PLAY_SOURCE="$LOCAL_PLAY"
if awk "BEGIN{exit !($TV_EXTRA_DELAY_SEC > 0)}" 2>/dev/null; then
    DELAY_MS=$(awk "BEGIN{printf \"%d\", $TV_EXTRA_DELAY_SEC*1000}")
    echo "back-TV extra audio delay: +${TV_EXTRA_DELAY_SEC}s (${DELAY_MS}ms) — inserting delay-relay stage"
    /usr/bin/ffmpeg -hide_banner -loglevel warning \
        -fflags nobuffer+discardcorrupt -flags low_delay \
        -i "$LOCAL_PLAY" \
        -c:v copy \
        -af "adelay=${DELAY_MS}|${DELAY_MS}:all=1" -c:a aac -b:a 160k -ar 48000 -ac 2 \
        -muxdelay 0 -muxpreload 0 -flush_packets 1 \
        -f mpegts "$TV_DELAY_RELAY_UDP" &
    TV_DELAY_PID=$!
    sleep 1
    PLAY_SOURCE="$TV_DELAY_RELAY_UDP"
fi
echo "ffplay reads from: ${PLAY_SOURCE}"

# Keep forcing sink for ~15s (WP may reassign to Mixer)
(
    for _ in $(seq 1 15); do
        sleep 1
        for id in $(pactl list sink-inputs 2>/dev/null | awk '
            /^Sink Input #/ { id=$3; gsub("#","",id) }
            /application.process.binary = "ffplay"/ { print id }
        '); do
            pactl move-sink-input "$id" "${HDMI_SINK}" 2>/dev/null || true
            pactl set-sink-input-mute "$id" 0 2>/dev/null || true
            pactl set-sink-input-volume "$id" 100% 2>/dev/null || true
        done
    done
) &

# No -alwaysontop (focus steal).
exec /usr/bin/ffplay \
    -hide_banner -loglevel warning \
    -fflags nobuffer+discardcorrupt \
    -flags low_delay \
    -framedrop \
    -sync ext \
    -window_title "${WINDOW_TITLE}" \
    -left "$X" -top "$Y" \
    -x "$W" -y "$H" \
    -fs \
    -noborder \
    "${PLAY_SOURCE}"
