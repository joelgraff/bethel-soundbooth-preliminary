#!/usr/bin/env bash
# Bridge software Mixer → PreSonus StudioLive USB return 1–2.
#
# Why: StudioLive USB is fixed 64ch S32_LE. PipeWire/Pulse sink volume on that
# device sticks at 0%/-inf (even with soft-mixer), so Mixer→node links are
# silent. This bridge reads Mixer.monitor and writes via an ALSA plug that
# expands stereo → 64ch (channels 0/1 only).
#
# Requires ~/.asoundrc pcm.presonus_foh (installed from audio-routing/alsa/).
# WirePlumber should disable stock PreSonus ACP nodes so hw:S32SX is free.
#
# Usage: start-presonus-foh-bridge.sh
# Systemd: presonus-foh-bridge.service

set -euo pipefail

LOG_TAG="presonus-foh-bridge"
ASOUNDRC="${HOME}/.asoundrc"
LATENCY_MS="${PRES_FOH_LATENCY_MS:-20}"

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# Wait for Mixer virtual sink (virtual-audio.service / pipewire-pulse)
for _ in $(seq 1 60); do
    if pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx Mixer; then
        break
    fi
    sleep 0.5
done
if ! pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx Mixer; then
    log "ERROR: Mixer sink not found"
    exit 1
fi

if ! grep -q 'pcm.presonus_foh' "${ASOUNDRC}" 2>/dev/null; then
    log "ERROR: ~/.asoundrc missing pcm.presonus_foh — install audio-routing/alsa/asoundrc-presonus-foh"
    exit 1
fi

# Ensure stock PipeWire is not holding the card (ACP disabled via WP rule)
if fuser /dev/snd/pcmC3D0p >/dev/null 2>&1; then
    log "WARNING: something already has S32SX playback open — bridge may fail"
fi

log "Starting Mixer.monitor → aplay presonus_foh (USB 1–2)"
exec parec \
    --device=Mixer.monitor \
    --format=s16le \
    --rate=48000 \
    --channels=2 \
    --latency-msec="${LATENCY_MS}" \
  | aplay \
    -D presonus_foh \
    -f S16_LE \
    -r 48000 \
    -c 2 \
    -B $((LATENCY_MS * 1000)) \
    --disable-softvol \
    -q
