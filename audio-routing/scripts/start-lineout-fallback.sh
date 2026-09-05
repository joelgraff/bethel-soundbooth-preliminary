#!/bin/bash
# start-lineout-fallback.sh — mirror the FOH mix to the motherboard line-out.
#
# WHY
# The PreSonus 32SX's USB link has failed repeatedly (see
# audio-routing/tests/usb-reset-checklist.md and the presonus-usb-watch.sh
# header). When it wedges, FOH goes silent and the only reliable fix is a
# physical power-cycle — useless mid-service. This is the contingency path:
# an analog feed of the SAME mix into board channel 32, over a cable that
# shares nothing with the USB link and cannot fail the same way.
#
# It runs ALL THE TIME by design. The value of a fallback is that switching
# to it costs one fader move at the board and no terminal, so it has to be
# already live when it is needed. Channel 32 stays muted until then.
#
# NOTE ON RUNNING BOTH AT ONCE: if channel 32 is up while USB audio is also
# working, the two paths arrive at slightly different latencies and will
# comb-filter against each other. Use one or the other, not both.
#
# WHAT IT CARRIES
# Mixer.monitor — exactly what the USB bridge sends the board, so the
# fallback and the primary carry identical content. System/event sounds are
# excluded at the source: GNOME event sounds are disabled
# (org.gnome.desktop.sound event-sounds=false) rather than filtered here,
# because Mixer is the session default sink and anything landing in it is
# indistinguishable downstream.

set -uo pipefail

# The SINK whose monitor we mirror — a node name, NOT a Pulse-style
# "<sink>.monitor" source name. pw-loopback resolves -C against PipeWire node
# names; handed "Mixer.monitor" it silently finds nothing, falls back to the
# DEFAULT SOURCE, and connects to that instead. On 2026-09-05 that default was
# the PreSonus board's own capture input, so the loopback ran
# board-in -> line-out -> board channel 32: a feedback loop, silent only
# because ch 32 was muted. Capturing a sink's monitor requires
# stream.capture.sink=true in the capture props (set on the exec line below).
SOURCE="${LINEOUT_SOURCE:-Mixer}"
SINK="${LINEOUT_SINK:-alsa_output.pci-0000_09_00.4.analog-stereo}"
LATENCY_MS="${LINEOUT_LATENCY_MS:-50}"

log() { echo "[lineout-fallback $(date +%H:%M:%S)] $*"; }

# Wait for both ends to exist — this starts alongside the rest of the audio
# stack and the Mixer sink is created by virtual-audio.service.
for i in $(seq 1 30); do
    if pactl list sinks short 2>/dev/null | grep -qE "[[:space:]]${SOURCE}[[:space:]]" && \
       pactl list sinks short 2>/dev/null | grep -q "$SINK"; then
        break
    fi
    [[ $i -eq 30 ]] && { log "ERROR: source '$SOURCE' or sink '$SINK' never appeared"; exit 1; }
    sleep 2
done

# Set the output level deterministically rather than inheriting whatever
# WirePlumber restored. This is a HARDWARE volume control on this card
# (Flags: HW_VOLUME_CTRL), so it attenuates the actual analog signal — it
# was found at 40% / -23.80 dB, which starves a mixer line input of ~24 dB
# of gain structure. Unity here, and ALL trimming happens at the board's
# channel-32 trim, which is where a sound operator expects it.
if [[ "${LINEOUT_SET_VOLUME:-1}" == "1" ]]; then
    pactl set-sink-volume "$SINK" "${LINEOUT_VOLUME:-100%}" 2>/dev/null \
        && log "output level → ${LINEOUT_VOLUME:-100%} (trim at the board, not here)"
    pactl set-sink-mute "$SINK" 0 2>/dev/null
fi

# Makeup gain on THIS path only.
#
# The Mixer bus runs about 30 dB below normal program level (measured
# 2026-09-05: RMS -44.2 dBFS, peak -33.0 dBFS, where program material should
# peak near -6). The USB path hides this because the board's USB return gain
# was trimmed to compensate years of it. The analog path has no such
# reserve: at the board, gain maxed, it was still quiet AND sounded dirty
# and over-compressed — which is what you hear when 30 dB of makeup gain at
# a mic preamp lifts the DAC noise floor along with the music.
#
# Applied to the loopback's playback stream, so the USB feed is untouched and
# needs no re-trim. PipeWire mixes in float32, so boosting here costs no
# quality — it uses more of the DAC's range rather than less.
#
# The real fix is upstream (Spotify's own volume slider is the likely
# culprit). When that is corrected, DROP THIS BACK or the analog path will
# clip: +20 dB on a -33 dBFS peak lands at -13 dBFS, but on a -6 dBFS peak
# it would be +14 dBFS of hard clipping.
apply_makeup_gain() {
    # 215% is +20 dB, NOT +115%. PulseAudio/PipeWire percentages are CUBIC:
    # gain = (pct/100)^3, so dB = 60*log10(pct/100). 1000% is +60 dB, which
    # on this bus would land peaks at +27 dBFS — total clipping. Verified
    # 2026-09-05: 215% reported 19.95 dB and moved the line-out from
    # peak -33.0 to -11.9 dBFS with zero clipped samples.
    local want="${LINEOUT_MAKEUP_GAIN:-215%}" id
    for _ in $(seq 1 20); do
        # $3 on the header line is "#3433" — pactl needs the bare integer, and
        # rejects the "#" form silently, which is why the first version of
        # this appeared to do nothing at all.
        id=$(pactl list sink-inputs 2>/dev/null | awk '
            /^Sink Input/ { id=$3; sub(/^#/, "", id) }
            /node.name = "output.FOH-Lineout-Fallback"/ { print id; exit }')
        if [[ -n "$id" ]]; then
            pactl set-sink-input-volume "$id" "$want" 2>/dev/null \
                && log "makeup gain → ${want} on stream ${id}"
            return
        fi
        sleep 1
    done
    log "WARNING: loopback stream never appeared; makeup gain NOT applied"
}
apply_makeup_gain &

log "mirroring ${SOURCE} → ${SINK} (latency ${LATENCY_MS}ms)"
exec pw-loopback \
    --capture-props="stream.capture.sink=true node.target=${SOURCE}" \
    --capture "$SOURCE" \
    --playback "$SINK" \
    --latency "${LATENCY_MS}" \
    --name "FOH-Lineout-Fallback"
