#!/bin/bash
# Relay: local capture (MPEG-TS tee from ffmpeg-capture.service) → SRT (Subsplash).
#
# This is the ONLY process that talks to Subsplash. It is a stream copy (no
# re-encode) of a dedicated local UDP tee ffmpeg-capture.service already
# publishes (separate port from the DP-4 display feed — unicast UDP only
# supports one reader per port), so it can be stopped/started independently —
# ending the livestream cleanly without touching ATEM capture or the DP-4 display.
#
# Stop stream (end of service): ~/bin/stop-live-stream.sh
# Start stream:                 ~/bin/start-live-stream.sh
#
# Config: ~/.config/soundbooth/ffmpeg-srt.conf (same file as capture)
# Service: systemctl --user status ffmpeg-srt-relay.service

set -euo pipefail

CONF="${HOME}/.config/soundbooth/ffmpeg-srt.conf"
if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

LOGLEVEL="${FFMPEG_LOGLEVEL:-info}"

if [[ -z "${FFMPEG_SRT_URL:-}" ]]; then
    echo "ERROR: FFMPEG_SRT_URL not set. Put it in $CONF" >&2
    exit 1
fi

# Dedicated tee leg from ffmpeg-capture (unicast UDP is exclusive — one reader
# per port — so this does NOT share the :5000 port ffplay/DP-4 reads).
RELAY_INPUT="${FFMPEG_SRT_RELAY_INPUT:-${FFMPEG_LOCAL_UDP_RELAY:-udp://127.0.0.1:5003?pkt_size=1316}}"
# Reading side needs the "@" bind form, matching start-ffmpeg-display.sh.
RELAY_INPUT="${RELAY_INPUT#udp://}"
RELAY_INPUT="${RELAY_INPUT#@}"
RELAY_INPUT="udp://@${RELAY_INPUT}"

# SRT open is one-shot: if DNS/network is down at open, ffmpeg exits immediately
# and systemd Restart=always retries. Wait for DNS of SRT hostname first so a
# transient boot-time DNS gap doesn't burn through StartLimitBurst.
# Override: FFMPEG_SRT_DNS_WAIT_SEC=0 to skip.
SRT_DNS_WAIT="${FFMPEG_SRT_DNS_WAIT_SEC:-120}"
if [[ "$SRT_DNS_WAIT" -gt 0 ]]; then
    srt_host=$(printf '%s' "${FFMPEG_SRT_URL}" | sed -n 's|^[a-zA-Z][a-zA-Z0-9+.-]*://\([^/?#:]*\).*|\1|p')
    if [[ -n "$srt_host" && ! "$srt_host" =~ ^[0-9.]+$ ]]; then
        echo "Waiting up to ${SRT_DNS_WAIT}s for DNS: ${srt_host}..."
        dns_ok=0
        for i in $(seq 1 "$SRT_DNS_WAIT"); do
            if getent hosts "$srt_host" &>/dev/null || host "$srt_host" &>/dev/null; then
                echo "  DNS ready after ${i}s: ${srt_host}"
                dns_ok=1
                break
            fi
            sleep 1
        done
        if [[ "$dns_ok" -ne 1 ]]; then
            echo "WARNING: DNS for ${srt_host} not ready after ${SRT_DNS_WAIT}s — starting anyway" >&2
        fi
    fi
fi

# Wait for ffmpeg-capture to actually be producing the relay tee —
# otherwise ffmpeg opens the SRT output against an empty input and idles.
echo "Waiting for ffmpeg-capture.service..."
for _ in $(seq 1 60); do
    if systemctl --user is-active --quiet ffmpeg-capture.service 2>/dev/null; then
        echo "  ffmpeg-capture active"
        sleep 2
        break
    fi
    sleep 1
done

echo "FFmpeg SRT relay (stream copy, no re-encode)"
echo "  from:   ${RELAY_INPUT}"
echo "  to:     ${FFMPEG_SRT_URL%%\?*}?…"

exec /usr/bin/ffmpeg \
    -hide_banner -loglevel "$LOGLEVEL" \
    -fflags nobuffer+genpts -flags low_delay \
    -thread_queue_size 1024 \
    -i "$RELAY_INPUT" \
    -c copy \
    -muxdelay 0 -muxpreload 0 -flush_packets 1 \
    -f mpegts "${FFMPEG_SRT_URL}"
