#!/bin/bash
# start-lineout-fallback.sh — mirror the FOH mix to the motherboard line-out.
#
# WHY
# The PreSonus 32SX's USB link has failed repeatedly (see
# audio-routing/tests/usb-reset-checklist.md and the presonus-usb-watch.sh
# header). When it wedges, FOH goes silent and the only reliable fix is a
# physical power-cycle — useless mid-service. This is the contingency path:
# an analog feed of the SAME mix into board channel 21, over a cable that
# shares nothing with the USB link and cannot fail the same way.
#
# CHANNEL MOVED: this fed board channel 32 originally and was re-patched to
# channel 21 (confirmed by the operator 2026-09-14). Every mention of ch 32
# in this file and in lineout-fallback.service was stale until then — which
# mattered, because those comments tell a mid-service operator which fader to
# reach for. Old commits and notes referring to ch 32 mean this same path.
#
# It runs ALL THE TIME by design. The value of a fallback is that switching
# to it costs one fader move at the board and no terminal, so it has to be
# already live when it is needed. Channel 21 stays muted until then.
#
# NOTE ON RUNNING BOTH AT ONCE: if channel 21 is up while USB audio is also
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
# board-in -> line-out -> board channel 21: a feedback loop, silent only
# because ch 21 was muted. Capturing a sink's monitor requires
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
# channel-21 trim, which is where a sound operator expects it.
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
    # 126% is +6 dB. Was 215% (+20 dB) while the board was receiving only the
    # L-R difference signal; restoring the centre (see the mono routing below)
    # hands back 13.1 dB on its own, so the makeup comes down by a matching
    # amount to leave the level at the board roughly where the operator
    # already had it trimmed.
    local want="${LINEOUT_MAKEUP_GAIN:-126%}" id
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
# MONO SUM ON ONE LEG, not stereo.
#
# Board channel 21 is a BALANCED input, so it computes (tip - ring). Fed a
# stereo signal (L on tip, R on ring) it therefore renders L-R: every
# centre-panned element — lead vocals above all — subtracts to nothing, and
# what survives is the decorrelated edges, which is why it sounded thin and
# "digitally dirty" rather than merely quiet. Measured 2026-09-05 on real
# program material: MID (L+R)/2 = -49.6 dBFS, SIDE (L-R)/2 = -62.7 dBFS,
# L/R correlation +0.910 — the board was hearing 13.1 dB less than it should,
# minus the vocals.
#
# --channels 1 makes the capture a mono downmix (audioconvert sums L+R), and
# audio.position=[FL] puts it on the tip alone with the ring at digital
# silence. The balanced input then computes (M - 0) = M: full centre content,
# correct level. This is also correct for an unbalanced TS input, and is safe
# if the ring happens to be shorted to sleeve, so it needs no assumption about
# which cable is in use.
#
# Do NOT "fix" this by sending the mono sum to BOTH legs — that gives a
# balanced input (M - M) = 0, i.e. total silence.
exec pw-loopback \
    --capture-props="stream.capture.sink=true node.target=${SOURCE}" \
    --capture "$SOURCE" \
    --playback "$SINK" \
    --playback-props="audio.position=[FL]" \
    --channels 1 \
    --latency "${LATENCY_MS}" \
    --name "FOH-Lineout-Fallback"
