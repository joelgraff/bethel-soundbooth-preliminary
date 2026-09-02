#!/bin/bash
# VLC startup for soundbooth presentation rig.
#
# Targets the sanctuary VLC TV by stable connector name (default DP-4),
# never a hard-coded Qt screen index alone — those shuffle after HDMI hotplug.
#
# Boot hardening:
#   - Discover Mutter Xwayland XAUTHORITY (user units often lack it)
#   - Wait until preferred connector is resolvable (not just "xrandr exits 0")
#   - Exit non-zero if still unresolved so systemd Restart= retries (never
#     fall back to a wrong screen / desktop)
#
# Pipeline (CPU-conscious):
#   - Fullscreen display uses the decoded capture path (no H.264 re-encode).
#   - HTTP :8081/stream.ts is a separate branch: H.264 via x264 ultrafast/zerolatency.
#   - Video = v4l2 UVC; audio = separate ATEM USB → PipeWire (input-slave). No shared
#     hardware clock → VLC cannot true-sync (see DEMUX_GET_TIME); use VLC_AUDIO_DESYNC_MS.
#
# Config: ~/.config/soundbooth/vlc-display.conf
# Overrides: VLC_OUTPUT_CONNECTOR, VLC_SCREEN_NUMBER, VLC_VIDEO_DEV, VLC_DISPLAY_WAIT_SEC,
#            VLC_AUDIO_SOURCE, VLC_AUDIO_DESYNC_MS, VLC_LIVE_CACHING_MS

set -euo pipefail

# shellcheck disable=SC1091
source "$HOME/bin/vlc-display-lib.sh"
soundbooth_load_vlc_conf
soundbooth_export_display_env || true

# Wait for multi-head map + preferred connector. Use *_into (not mon=$(wait)) so
# export XAUTHORITY sticks in this shell — $(…) was dropping the Mutter cookie and
# VLC launched with XAUTHORITY unset (Qt UI failed / window on booth desktop).
MON=""
if ! soundbooth_wait_for_vlc_display_into MON; then
    echo "Refusing to start VLC on a fallback screen — systemd will retry" >&2
    exit 1
fi

# Belt-and-suspenders: ensure auth is present even if wait path changes later
if ! soundbooth_export_display_env || [[ -z "${XAUTHORITY:-}" || ! -f "${XAUTHORITY}" ]]; then
    echo "ERROR: XAUTHORITY missing after display wait (DISPLAY=${DISPLAY:-}) — systemd will retry" >&2
    exit 1
fi

SCREEN_NUM=$(echo "$MON" | awk '{print $1}')
CONN=$(echo "$MON" | awk '{print $2}')
GEOM=$(echo "$MON" | awk '{print $3"x"$4"+"$5"+"$6}')
echo "VLC fullscreen → connector=${CONN} qt-screen=${SCREEN_NUM} geom=${GEOM}"
xrandr --listmonitors 2>/dev/null || true

LIVE_CACHING_MS="${VLC_LIVE_CACHING_MS:-300}"
# When FFmpeg owns /dev/video0 for SRT, VLC only displays the local MPEG-TS feed.
# Prefer UDP local feed from FFmpeg (stable multi-client). Override with VLC_LOCAL_STREAM_URL.
LOCAL_STREAM_URL="${VLC_LOCAL_STREAM_URL:-udp://@127.0.0.1:5000}"
USE_FFMPEG_FEED=0
if systemctl --user is-active --quiet ffmpeg-capture.service 2>/dev/null \
    || [[ "${VLC_USE_FFMPEG_FEED:-auto}" == "1" ]] \
    || [[ "${VLC_USE_FFMPEG_FEED:-auto}" == "yes" ]]; then
    USE_FFMPEG_FEED=1
fi
# Auto: if video device is busy (FFmpeg holds capture), use FFmpeg feed
if [[ "${VLC_USE_FFMPEG_FEED:-auto}" == "auto" ]] && fuser "$VIDEO_DEV" &>/dev/null; then
    USE_FFMPEG_FEED=1
fi

echo "X11: DISPLAY=${DISPLAY} XAUTHORITY=${XAUTHORITY}"

if [[ $USE_FFMPEG_FEED -eq 1 ]]; then
    echo "VLC mode: display FFmpeg local feed (no V4L2 capture) → ${LOCAL_STREAM_URL}"
    echo "Waiting for FFmpeg (ffmpeg-capture.service / UDP :5000)..."
    for _ in $(seq 1 60); do
        if systemctl --user is-active --quiet ffmpeg-capture.service 2>/dev/null \
            && ss -uln 2>/dev/null | grep -q ':5000'; then
            echo "Local UDP feed ready"
            break
        fi
        # Also accept active FFmpeg even if ss format differs
        if pgrep -f 'ffmpeg.*tee' &>/dev/null && systemctl --user is-active --quiet ffmpeg-capture.service; then
            sleep 2
            echo "FFmpeg active — starting VLC display"
            break
        fi
        sleep 1
    done
    # Display-only: A/V already muxed (FFmpeg audio delay applied at capture)
    exec /usr/bin/vlc \
      --qt-fullscreen-screennumber="${SCREEN_NUM}" \
      --fullscreen \
      --aspect-ratio=16:9 \
      --network-caching="${LIVE_CACHING_MS}" \
      --live-caching="${LIVE_CACHING_MS}" \
      --clock-synchro=0 \
      --no-audio-time-stretch \
      --qt-minimal-view \
      "${LOCAL_STREAM_URL}"
fi

# --- Legacy path: VLC owns capture (no ffmpeg-capture) ---
echo "Waiting for capture device ${VIDEO_DEV}..."
for _ in $(seq 1 45); do
    if [[ -e "$VIDEO_DEV" ]]; then
        echo "Capture ready: $VIDEO_DEV"
        break
    fi
    sleep 1
done
if [[ ! -e "$VIDEO_DEV" ]]; then
    echo "WARNING: $VIDEO_DEV not present yet — VLC will start anyway" >&2
fi

# ATEM program audio is a separate USB Audio class device (not in the UVC stream).
ATEM_AUDIO_SOURCE="${VLC_AUDIO_SOURCE:-}"
if [[ -z "$ATEM_AUDIO_SOURCE" ]]; then
    ATEM_AUDIO_SOURCE=$(pactl list short sources 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} $2 ~ /Blackmagic|ATEM/ && $2 !~ /\.monitor$/ {print $2; exit}')
fi
if [[ -z "$ATEM_AUDIO_SOURCE" ]]; then
    echo "WARNING: no ATEM Pulse source found — starting video-only" >&2
    INPUT_SLAVE_ARGS=()
else
    INPUT_SLAVE_ARGS=( ":input-slave=pulse://${ATEM_AUDIO_SOURCE}" )
fi

AUDIO_DESYNC_MS="${VLC_AUDIO_DESYNC_MS:-2000}"

# Display + optional local HTTP (legacy when FFmpeg SRT is not used)
SOUT='#duplicate{dst=display{delay=0},dst="transcode{vcodec=h264,vb=3000,acodec=mpga,ab=128,channels=2,samplerate=48000,venc=x264{preset=ultrafast,tune=zerolatency,keyint=60,bframes=0,aud=1}}:http{mux=ts,dst=:8081/stream.ts}"}'

echo "VLC mode: V4L2 capture + display; HTTP H.264 on :8081 (legacy)"
echo "VLC audio: source=${ATEM_AUDIO_SOURCE:-none} desync_ms=${AUDIO_DESYNC_MS} live_caching_ms=${LIVE_CACHING_MS}"

exec /usr/bin/vlc \
  --qt-fullscreen-screennumber="${SCREEN_NUM}" \
  --fullscreen \
  --aspect-ratio=16:9 \
  --live-caching="${LIVE_CACHING_MS}" \
  --network-caching="${LIVE_CACHING_MS}" \
  --sout-mux-caching="${LIVE_CACHING_MS}" \
  --clock-synchro=0 \
  --no-audio-time-stretch \
  --audio-desync="${AUDIO_DESYNC_MS}" \
  --qt-minimal-view \
  "v4l2://${VIDEO_DEV}" \
  "${INPUT_SLAVE_ARGS[@]}" \
  :v4l2-width=1920 \
  :v4l2-height=1080 \
  :v4l2-fps=30 \
  --sout="${SOUT}" \
  --sout-keep
