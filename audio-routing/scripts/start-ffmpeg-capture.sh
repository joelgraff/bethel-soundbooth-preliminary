#!/bin/bash
# FFmpeg ATEM capture → local UDP MPEG-TS for sanctuary display + livestream relay.
#
# Owns /dev/video0 exclusively. Always-on: this process does NOT talk to Subsplash
# directly. Display on DP-4 is handled by ffmpeg-display.service (ffplay); the
# livestream leg is ffmpeg-srt-relay.service, which reads its own dedicated
# local UDP tee below (:5003 by default) and can be stopped/started
# independently (see stop-live-stream.sh / start-live-stream.sh) without
# touching capture or the TV.
#
# Config: ~/.config/soundbooth/ffmpeg-srt.conf
# Service: systemctl --user status ffmpeg-capture.service

set -euo pipefail

CONF="${HOME}/.config/soundbooth/ffmpeg-srt.conf"
if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

VIDEO_DEV="${FFMPEG_VIDEO_DEV:-/dev/video0}"
VIDEO_SIZE="${FFMPEG_VIDEO_SIZE:-1920x1080}"
VIDEO_FPS="${FFMPEG_VIDEO_FPS:-30}"
# Lip-sync adelay (seconds). Raw ATEM path: audio leads ~0.25s → delay 0.25.
# 2026-07-30: cleared then restored after A/B (0=lead, 0.25=match lead amount).
# Override anytime via FFMPEG_AUDIO_DELAY_SEC in ~/.config/soundbooth/ffmpeg-srt.conf
AUDIO_DELAY_SEC="${FFMPEG_AUDIO_DELAY_SEC:-0.25}"
# Local feed for ffplay on DP-4.
LOCAL_UDP="${FFMPEG_LOCAL_UDP:-udp://239.255.42.42:5000?pkt_size=1316&ttl=1}"
LOCAL_HTTP="${FFMPEG_LOCAL_HTTP:-}"
ENCODE_MODE="${FFMPEG_ENCODE_MODE:-x264}"
VBITRATE="${FFMPEG_VBITRATE:-4500k}"
ABITRATE="${FFMPEG_ABITRATE:-160k}"
LOGLEVEL="${FFMPEG_LOGLEVEL:-info}"

# ATEM USB audio: prefer ALSA (reliable). Pulse "Exec format error" is common with
# PipeWire after restarts; card name is "Extreme" (arecord -l).
AUDIO_BACKEND="${FFMPEG_AUDIO_BACKEND:-alsa}"   # alsa | pulse
ATEM_AUDIO="${FFMPEG_AUDIO_SOURCE:-}"
if [[ -z "$ATEM_AUDIO" ]]; then
    if [[ "$AUDIO_BACKEND" == "pulse" ]]; then
        ATEM_AUDIO=$(pactl list short sources 2>/dev/null \
            | awk 'BEGIN{IGNORECASE=1} $2 ~ /Blackmagic|ATEM/ && $2 !~ /\.monitor$/ {print $2; exit}')
    else
        # plughw: resample/buffer via ALSA plugin — more stable than raw hw: for long lives
        if [[ -d /proc/asound/Extreme ]]; then
            ATEM_AUDIO="plughw:Extreme,0"
        else
            ATEM_AUDIO="plughw:Extreme,0"
        fi
    fi
fi
if [[ -z "$ATEM_AUDIO" ]]; then
    echo "ERROR: no ATEM audio source found" >&2
    exit 1
fi
# Prefer plughw even if conf still says hw: (intermittent underruns on long streams)
if [[ "$ATEM_AUDIO" == hw:Extreme,0 ]]; then
    ATEM_AUDIO="plughw:Extreme,0"
fi
AUDIO_FMT="${FFMPEG_AUDIO_FMT:-$AUDIO_BACKEND}"
[[ "$AUDIO_FMT" == "alsa" || "$AUDIO_FMT" == "pulse" ]] || AUDIO_FMT=alsa

echo "Waiting for capture device ${VIDEO_DEV}..."
for _ in $(seq 1 60); do
    if [[ -e "$VIDEO_DEV" ]]; then
        if fuser "$VIDEO_DEV" &>/dev/null; then
            echo "  ${VIDEO_DEV} busy; waiting..."
        else
            echo "Capture ready: $VIDEO_DEV"
            break
        fi
    fi
    sleep 1
done
if [[ ! -e "$VIDEO_DEV" ]]; then
    echo "ERROR: $VIDEO_DEV missing" >&2
    exit 1
fi
if fuser "$VIDEO_DEV" &>/dev/null; then
    echo "ERROR: $VIDEO_DEV still busy" >&2
    fuser -v "$VIDEO_DEV" 2>&1 || true
    exit 1
fi

# Cold boot race: udev/ACL on UVC can lag → Permission denied for a few seconds
echo "Waiting for openable ${VIDEO_DEV}..."
for _ in $(seq 1 30); do
    if ( exec 3<>"$VIDEO_DEV" ) 2>/dev/null; then
        echo "  ${VIDEO_DEV} openable"
        break
    fi
    sleep 1
done

RENDER_DEV="${FFMPEG_RENDER_DEV:-/dev/dri/renderD128}"
USE_VAAPI=0
[[ "$ENCODE_MODE" == "vaapi" && -e "$RENDER_DEV" ]] && USE_VAAPI=1

# Extra local copies for booth multiview / probes / livestream relay (does not
# fight ffplay on :5000). Unicast UDP is exclusive — only one reader per port —
# so each consumer gets its own dedicated port rather than sharing one.
LOCAL_UDP_PREVIEW="${FFMPEG_LOCAL_UDP_PREVIEW:-udp://127.0.0.1:5001?pkt_size=1316}"
# Optional free probe port for av-sync-calibrate (no default reader). Empty to disable.
LOCAL_UDP_PROBE="${FFMPEG_LOCAL_UDP_PROBE:-udp://127.0.0.1:5002?pkt_size=1316}"
# Feeds ffmpeg-srt-relay.service (the only thing that talks to Subsplash).
LOCAL_UDP_RELAY="${FFMPEG_LOCAL_UDP_RELAY:-udp://127.0.0.1:5003?pkt_size=1316}"

# All local legs are onfail=ignore (layout hygiene only) — none of them should be
# able to take the shared encode down. Livestream delivery lives entirely in
# ffmpeg-srt-relay.service now, so a Subsplash outage can never touch this process.
TEE_OUT=""
if [[ -n "${LOCAL_UDP// }" ]]; then
    TEE_OUT="[f=mpegts:onfail=ignore]${LOCAL_UDP}"
fi
if [[ -n "${LOCAL_UDP_PREVIEW// }" ]]; then
    [[ -n "$TEE_OUT" ]] && TEE_OUT+="|"
    TEE_OUT+="[f=mpegts:onfail=ignore]${LOCAL_UDP_PREVIEW}"
fi
if [[ -n "${LOCAL_UDP_PROBE// }" ]]; then
    [[ -n "$TEE_OUT" ]] && TEE_OUT+="|"
    TEE_OUT+="[f=mpegts:onfail=ignore]${LOCAL_UDP_PROBE}"
fi
if [[ -n "${LOCAL_UDP_RELAY// }" ]]; then
    [[ -n "$TEE_OUT" ]] && TEE_OUT+="|"
    TEE_OUT+="[f=mpegts:onfail=ignore]${LOCAL_UDP_RELAY}"
fi
if [[ -n "${LOCAL_HTTP// }" ]]; then
    [[ -n "$TEE_OUT" ]] && TEE_OUT+="|"
    TEE_OUT+="[f=mpegts:listen=1:onfail=ignore]${LOCAL_HTTP}"
fi
if [[ -z "$TEE_OUT" ]]; then
    echo "ERROR: no local output configured (LOCAL_UDP/LOCAL_UDP_PREVIEW/LOCAL_UDP_PROBE/LOCAL_HTTP all empty)" >&2
    exit 1
fi
echo "  tee: ${TEE_OUT}"

echo "FFmpeg capture (local-only; livestream relay is a separate service)"
echo "  video:  v4l2 ${VIDEO_DEV} ${VIDEO_SIZE}@${VIDEO_FPS}"
echo "  audio:  ${AUDIO_FMT}:${ATEM_AUDIO} delay=${AUDIO_DELAY_SEC}s"
echo "  encode: $([[ $USE_VAAPI -eq 1 ]] && echo h264_vaapi || echo libx264) ${VBITRATE}"
echo "  local:  ${LOCAL_UDP}"
echo "  preview:${LOCAL_UDP_PREVIEW:-(none)}"
echo "  relay:  ${LOCAL_UDP_RELAY:-(none)}"

# Separate USB video + USB audio clocks drift over long services → dropouts.
# Larger audio queue + aresample=async keeps continuous AAC.
# Do NOT use_wallclock_as_timestamps on both inputs — breaks MPEG-TS packet timing
# and left ffplay blank (stream present, 0 frames).
common_in=(
    -hide_banner -loglevel "$LOGLEVEL"
    -fflags nobuffer+genpts -flags low_delay
    -thread_queue_size 1024
    -f v4l2 -input_format mjpeg -video_size "$VIDEO_SIZE" -framerate "$VIDEO_FPS"
    -i "$VIDEO_DEV"
    -thread_queue_size 8192
    -f "$AUDIO_FMT"
)
if [[ "$AUDIO_FMT" == "alsa" ]]; then
    common_in+=( -sample_rate 48000 -channels 2 )
fi
common_in+=( -i "$ATEM_AUDIO" )

# Subsplash-friendly (and CDN-friendly generally): regular IDR, headers repeated,
# main@L4.0, no B-frames. ATEM often delivers 24 fps — align GOP to ~2s. The
# relay does a stream copy, so these settings are what actually reach Subsplash.
GOP=$((VIDEO_FPS * 2))
[[ "$GOP" -lt 48 ]] && GOP=48

# Delay audio samples (matches VLC_AUDIO_DESYNC_MS=2000). adelay is more reliable
# for live MPEG-TS than -itsoffset alone. Unit is milliseconds per channel.
AUDIO_DELAY_MS=$(awk -v s="${AUDIO_DELAY_SEC}" 'BEGIN { printf "%d", s*1000 + 0.5 }')
[[ "${AUDIO_DELAY_MS}" -lt 0 ]] && AUDIO_DELAY_MS=0
# Mild async (100 samples) avoids non-monotonic DTS that blanked the local feed;
# still absorbs small USB clock drift. adelay = lip-sync (VLC was 2000 ms).
AUDIO_FILTER="aresample=48000:async=100,adelay=${AUDIO_DELAY_MS}|${AUDIO_DELAY_MS}:all=1"
echo "  audio delay: ${AUDIO_DELAY_MS} ms + mild aresample async"

if [[ $USE_VAAPI -eq 1 ]]; then
    exec /usr/bin/ffmpeg \
        -init_hw_device "vaapi=va:${RENDER_DEV}" -filter_hw_device va \
        "${common_in[@]}" \
        -filter_complex "[0:v]format=nv12,hwupload=extra_hw_frames=64[v];[1:a]${AUDIO_FILTER}[a]" \
        -map "[v]" -map "[a]" \
        -c:v h264_vaapi -bf 0 -g "$GOP" \
        -b:v "$VBITRATE" -maxrate "$VBITRATE" -bufsize 2M \
        -c:a aac -b:a "$ABITRATE" -ar 48000 -ac 2 \
        -muxdelay 0 -muxpreload 0 \
        -f tee "$TEE_OUT"
else
    # Software x264 — main + repeat-headers so CDNs can latch mid-stream
    exec /usr/bin/ffmpeg \
        "${common_in[@]}" \
        -filter_complex "[1:a]${AUDIO_FILTER}[a]" \
        -map 0:v -map "[a]" \
        -c:v libx264 -preset veryfast -tune zerolatency \
        -profile:v main -level 4.0 -pix_fmt yuv420p \
        -bf 0 -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
        -force_key_frames "expr:gte(t,n_forced*2)" \
        -x264-params "repeat-headers=1:aud=1:bframes=0:keyint=${GOP}:min-keyint=${GOP}:scenecut=0" \
        -b:v "$VBITRATE" -maxrate "$VBITRATE" -bufsize 2M \
        -c:a aac -b:a "$ABITRATE" -ar 48000 -ac 2 \
        -muxdelay 0 -muxpreload 0 -flush_packets 1 \
        -f tee "$TEE_OUT"
fi
