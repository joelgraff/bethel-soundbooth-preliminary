#!/bin/bash
# ffplay-audio-guard.sh — keep the program-TV audio (ffplay) off the FOH path.
#
# WHY
# ffplay carries the livestream/program mix and must only ever play to the HDMI
# TV sink. start-ffmpeg-display.sh pins it there with PULSE_SINK, but that pin
# is only honoured while the sink exists. If the sink vanishes — the HDMI-over-Cat
# extender is reset or power-cycled, DP-4 hot-unplugs, the GPU audio card drops to
# profile "off" — WirePlumber silently moves the stream to the DEFAULT sink, which
# is Mixer, i.e. the house speakers. It does NOT move it back when the sink returns.
# Root-caused and reproduced 2026-09-20 after the extender was reset mid-stream
# (see STATUS.md, and the hdmi-audio-card-parks-off notes). It had already happened
# at least twice before with the cause unknown.
#
# WHAT IT DOES
# Reacts to PulseAudio/PipeWire events (pactl subscribe), plus a slow periodic
# sweep in case an event is missed, and reconciles every ffplay sink-input:
#   * HDMI sink present  -> ffplay belongs on it (restores it after a hot-replug)
#   * HDMI sink missing  -> PARK ffplay on LocalLive (a null sink nothing listens
#                           to) so it is silent instead of landing on Mixer, THEN
#                           try to bring the card back to its HDMI profile
# When the sink comes back, the next reconcile moves ffplay onto it again.
#
# WHAT IT DOES NOT DO
# It never touches any stream that is not ffplay, never touches Mixer/FOH, and
# does nothing at all while ffplay is not running. Worst-case leak is the sub-second
# gap between the sink disappearing and this reacting; it cannot prevent that gap
# (WirePlumber's own fallback and pactl move race each other).
# node.dont-fallback was tried and does NOT work on WirePlumber 0.4.17 — don't retry.
#
# Usage: ffplay-audio-guard.sh          run forever (ffplay-audio-guard.service)
#        ffplay-audio-guard.sh --once   reconcile once and exit
#
# Overrides (environment; mainly for testing):
#   FFPLAY_GUARD_APP       stream to guard, matched exactly against application.name /
#                          application.process.binary (default: ffplay)
#   FFPLAY_GUARD_HDMI_SINK HDMI sink name (default: FFMPEG_HDMI_AUDIO_SINK from
#                          ~/.config/soundbooth/ffmpeg-srt.conf, else the DP-4 sink)
#   FFPLAY_GUARD_PARK_SINK sink to park on while HDMI is missing (default: LocalLive)
#   FFPLAY_GUARD_CARD      HDMI audio card to repair; empty = never touch profiles
#   FFPLAY_GUARD_PROFILE   profile that exposes the HDMI sink

set -uo pipefail

CONF="${HOME}/.config/soundbooth/ffmpeg-srt.conf"

# Read one variable from the conf in a subshell so the rest of it (SRT URL/keys)
# never enters this process's environment.
conf_sink=""
if [[ -f "$CONF" ]]; then
    conf_sink=$( (source "$CONF" >/dev/null 2>&1; echo "${FFMPEG_HDMI_AUDIO_SINK:-}") )
fi

APP="${FFPLAY_GUARD_APP:-ffplay}"
HDMI_SINK="${FFPLAY_GUARD_HDMI_SINK:-${conf_sink:-alsa_output.pci-0000_07_00.1.hdmi-stereo-extra1}}"
PARK_SINK="${FFPLAY_GUARD_PARK_SINK:-LocalLive}"
CARD="${FFPLAY_GUARD_CARD-alsa_card.pci-0000_07_00.1}"
PROFILE="${FFPLAY_GUARD_PROFILE:-output:hdmi-stereo-extra1}"

SWEEP_SEC=10            # periodic reconcile even with no events
PARKED_SWEEP_SEC=1      # ...and much faster while parked, so a sink that returns
                        # is picked up even if its "new sink" event came too early
                        # (the event can precede the sink appearing in pactl's list)
PARKED=0                # set by reconcile(): 1 while ffplay is parked on PARK_SINK
LAST_RECONCILE_US=0     # set by reconcile(), microseconds since epoch
COALESCE_MAX_US=500000  # cap on the post-event burst-coalescing window
PROFILE_RETRY_SEC=10    # min gap between card-profile repair attempts
LAST_PROFILE_TRY=0

log() { printf '[ffplay-audio-guard %(%H:%M:%S)T] %s\n' -1 "$*"; }

# "<input id>\t<sink id>" for each sink-input whose application.name or
# application.process.binary is exactly $APP.
guarded_inputs() {
    pactl list sink-inputs 2>/dev/null | awk -v app="$APP" '
        BEGIN { RS = ""; FS = "\n" }
        {
            id = ""; sink = ""; hit = 0
            for (i = 1; i <= NF; i++) {
                line = $i; sub(/^[ \t]+/, "", line)
                if (line ~ /^Sink Input #/)      { id = line;   sub(/^Sink Input #/, "", id) }
                else if (line ~ /^Sink: /)       { sink = line; sub(/^Sink: /, "", sink) }
                else if (line == "application.name = \"" app "\"" ||
                         line == "application.process.binary = \"" app "\"") hit = 1
            }
            if (hit && id != "") print id "\t" sink
        }'
}

sink_id_of() {
    pactl list short sinks 2>/dev/null | awk -v n="$1" '$2 == n { print $1; exit }'
}

sink_name_of() {
    pactl list short sinks 2>/dev/null | awk -v i="$1" '$1 == i { print $2; exit }'
}

# The sink normally disappears because the card left its HDMI profile (WirePlumber
# re-picks the "best" profile on hotplug, which may be a different HDMI output or
# "off"). Put it back — but rate-limited, and only when we already know ffplay is
# running and the sink is missing.
restore_card_profile() {
    [[ -n "$CARD" ]] || return 0
    local now; printf -v now '%(%s)T' -1
    (( now - LAST_PROFILE_TRY >= PROFILE_RETRY_SEC )) || return 0
    LAST_PROFILE_TRY=$now
    log "HDMI sink '$HDMI_SINK' missing — setting $CARD to $PROFILE"
    pactl set-card-profile "$CARD" "$PROFILE" 2>/dev/null \
        || log "WARNING: could not set profile $PROFILE on $CARD (card absent or output unavailable)"
}

# Move every guarded input that is not already on $1 (a sink name) onto it.
route_inputs() {
    local target="$1" target_id inputs id sink from
    target_id=$(sink_id_of "$target")
    if [[ -z "$target_id" ]]; then
        log "ERROR: target sink '$target' does not exist; cannot reroute $APP"
        return 1
    fi
    inputs=$(guarded_inputs)
    while IFS=$'\t' read -r id sink; do
        [[ -n "$id" && "$sink" != "$target_id" ]] || continue
        from=$(sink_name_of "$sink")
        if pactl move-sink-input "$id" "$target" 2>/dev/null; then
            if [[ "$target" == "$PARK_SINK" ]]; then
                log "PARKED $APP input $id: ${from:-sink $sink} -> $PARK_SINK (HDMI sink missing)"
            else
                log "RESTORED $APP input $id: ${from:-sink $sink} -> $HDMI_SINK"
            fi
        else
            log "ERROR: move-sink-input $id -> $target failed"
        fi
    done <<< "$inputs"
}

reconcile() {
    PARKED=0
    LAST_RECONCILE_US=${EPOCHREALTIME/./}
    [[ -n "$(guarded_inputs)" ]] || return 0

    if [[ -n "$(sink_id_of "$HDMI_SINK")" ]]; then
        route_inputs "$HDMI_SINK"
        return
    fi

    # HDMI sink is gone. Silence ffplay FIRST; only then try to repair the card —
    # a slow profile switch must never lengthen the time program audio is on Mixer.
    PARKED=1
    route_inputs "$PARK_SINK"
    restore_card_profile
    if [[ -n "$(sink_id_of "$HDMI_SINK")" ]]; then    # repair can be instantaneous
        PARKED=0
        route_inputs "$HDMI_SINK"
    fi
}

if [[ "${1:-}" == "--once" ]]; then
    reconcile
    exit $?
fi

SUB_PID=""
trap '[[ -n "$SUB_PID" ]] && kill "$SUB_PID" 2>/dev/null' EXIT
trap 'exit 0' TERM INT

log "guarding '$APP': HDMI sink '$HDMI_SINK', park on '$PARK_SINK', repair ${CARD:-<disabled>} -> $PROFILE"

# Only these events can change where ffplay should be. Every pactl call this script
# makes also emits client new/remove events, so reacting to *everything* would
# have it wake itself up forever.
relevant() { [[ "$1" == *sink* || "$1" == *card* || "$1" == *server* ]]; }

while true; do
    # (Re)connect to the event stream. pactl subscribe exits if pipewire-pulse
    # restarts, so this must survive that instead of dying and exhausting the
    # unit's start-limit during a long audio outage.
    # stdbuf -oL is required: pactl block-buffers when stdout is a pipe, which
    # delays events by minutes — verified 2026-09-20, the guard never reacted without it.
    coproc SUB { exec stdbuf -oL pactl subscribe 2>/dev/null; }   # sets SUB_PID, SUB[0]
    exec {EV}<&"${SUB[0]}"

    reconcile   # act on current state before waiting for anything

    while true; do
        interval=$(( PARKED ? PARKED_SWEEP_SEC : SWEEP_SEC ))
        read -r -t "$interval" -u "$EV" line
        rc=$?
        (( rc == 0 || rc > 128 )) || break                # EOF/error: reconnect

        if (( rc == 0 )) && relevant "$line"; then
            pending=1
            while (( pending )); do
                pending=0
                reconcile
                # Coalesce the burst our own move (and the hotplug) generate; if
                # any relevant event arrived while we were busy, go around once
                # more. Bounded: irrelevant events (any client running pactl)
                # would otherwise keep this read from ever timing out.
                deadline=$(( ${EPOCHREALTIME/./} + COALESCE_MAX_US ))
                while read -r -t 0.2 -u "$EV" line; do
                    relevant "$line" && pending=1
                    (( ${EPOCHREALTIME/./} < deadline )) || break
                done
            done
        elif (( rc > 128 || ${EPOCHREALTIME/./} - LAST_RECONCILE_US >= interval * 1000000 )); then
            # Periodic sweep. Checked on irrelevant events too, so a chatty
            # pactl client cannot starve it by keeping read from timing out.
            reconcile
        fi
    done

    exec {EV}<&-
    kill "$SUB_PID" 2>/dev/null
    wait "$SUB_PID" 2>/dev/null
    log "event stream closed (audio server restarting?) — reconnecting in 2s"
    sleep 2
done
