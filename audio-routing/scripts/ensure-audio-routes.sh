#!/bin/bash
# ensure-audio-routes.sh
#
# Belt-and-suspenders script to force software audio sources onto the
# Presonus 32SX (via the "Mixer" virtual sink or directly).
#
# Usage:
#   ./ensure-audio-routes.sh
#   ./ensure-audio-routes.sh --dry-run
#
# Place in soundbooth-project/audio-routing/scripts/
# You can call it from a systemd service, timer, or manually.
#
# Policy reminder:
#   All software audio → Presonus board
#   VLC is deliberately excluded (HDMI TVs)

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "=== DRY RUN ==="
fi

log() { echo "[$(date +%H:%M:%S)] $*"; }

TARGET_SINK="Mixer"          # Preferred stable target for software
# Fallback: you can change to the full Presonus node name if needed:
# TARGET_SINK="alsa_output.usb-PreSonus_StudioLive_32SX_...multichannel-output"

# FreeShow master volume lives in ~/.config/freeshow/settings.json ("volume": 1.0).
# Was 0.1 (10%) which made PipeWire boosts almost useless. Keep that file at 1.0.
#
# PipeWire percentages below were 150%/50% while the FOH path was broken
# (volume stuck at 0%/-inf — see STATUS.md 2026-08-02) and people boosted app
# volume to compensate for what sounded too quiet. Once that bug was fixed
# and AUX0/1 started passing at clean unity gain, those boosts clipped the
# board hard. Operator re-tuned by ear post-fix (2026-08-02 evening):
# Spotify and FreeShow perceived-loudness-matched at 33% each (FreeShow's own
# in-app volume stays at 1.0 per above; 33% is the PipeWire stream level on
# top of that).
# Override: FREESHOW_VOLUME_PCT=40 SOFTWARE_VOLUME_PCT=33 ~/bin/ensure-audio-routes.sh
#
# Re-tuned 50% 2026-09-04 (was 33%) — operator found FreeShow's actual media
# volume (its embedded LibVLC player, see apply_software_levels() below) had
# been running unmanaged and maxed at 100% the whole time, unrelated to this
# 33%/50% number; that number only ever applied to FreeShow's OTHER stream
# (application.name=Chromium). 50% is the operator's ear-tuned level for the
# newly-managed LibVLC stream; kept the same for both since they're both
# "FreeShow" as far as an operator adjusting one knob is concerned.
FREESHOW_VOLUME_PCT="${FREESHOW_VOLUME_PCT:-50}"
SOFTWARE_VOLUME_PCT="${SOFTWARE_VOLUME_PCT:-33}"

SOFTWARE_PATTERNS=(
    "spotify"
    "chromium"   # FreeShow (Electron) often appears as application.name=Chromium
    "vivaldi"
    "firefox"
    "free show"
    "freeshow"
    "electron"
    # add more as needed
)

VLC_PATTERN="vlc"   # We deliberately leave VLC alone

get_sink_id() {
    pactl list short sinks | awk -v name="$1" 'index($2, name) {print $1; exit}'
}

# Returns the numeric Sink id a sink-input is currently connected to.
sink_input_sink_id() {
    pactl list sink-inputs 2>/dev/null | awk -v want="$1" '
        $1=="Sink" && $2=="Input" { cur=$3; gsub("#","",cur); next }
        cur==want && $1=="Sink:" { print $2; exit }
    '
}

# Returns application.process.binary for a sink-input id (best-effort; mawk-safe)
sink_input_binary() {
    pactl list sink-inputs 2>/dev/null | awk -v want="$1" '
        $1=="Sink" && $2=="Input" { cur=$3; gsub("#","",cur) }
        cur==want && /application\.process\.binary/ {
            line=$0
            sub(/[^"]*"/, "", line)   # drop through opening quote
            sub(/".*/, "", line)      # drop closing quote and rest
            print line
            exit
        }
    '
}

move_sink_input() {
    local input_id="$1"
    local sink_name="$2"
    local bin vol
    if $DRY_RUN; then
        log "DRY: pactl move-sink-input $input_id $sink_name"
    else
        log "Moving sink-input $input_id → $sink_name"
        pactl move-sink-input "$input_id" "$sink_name" || true
        pactl set-sink-input-mute "$input_id" 0 2>/dev/null || true
        bin=$(sink_input_binary "$input_id" || true)
        if [[ "${bin}" == "freeshow" ]]; then
            vol="${FREESHOW_VOLUME_PCT}%"
            log "FreeShow stream $input_id volume → ${vol}"
        else
            vol="${SOFTWARE_VOLUME_PCT}%"
        fi
        pactl set-sink-input-volume "$input_id" "$vol" 2>/dev/null || true
    fi
}

# Keep WirePlumber restore-stream aligned with our % targets (channelVolumes: 100%=1.0).
fix_stream_restore_levels() {
    local rs="${HOME}/.local/state/wireplumber/restore-stream"
    local lin_fs lin_soft
    [[ -f "$rs" ]] || return 0
    lin_fs=$(awk -v p="${FREESHOW_VOLUME_PCT}" 'BEGIN { printf "%.4g", p/100.0 }')
    lin_soft=$(awk -v p="${SOFTWARE_VOLUME_PCT}" 'BEGIN { printf "%.4g", p/100.0 }')
    local tmp
    tmp=$(mktemp)
    sed -E \
        -e 's|^(Output/Audio:media.role:Movie:channelVolumes=).*|\1 1.0;1.0;|' \
        -e "s|^(Output/Audio:media.role:Music:channelVolumes=).*|\\1 ${lin_soft};${lin_soft};|" \
        -e "s|^(Output/Audio:application.name:Chromium:channelVolumes=).*|\\1 ${lin_fs};${lin_fs};|" \
        "$rs" >"$tmp" && mv "$tmp" "$rs"
    sed -i -E 's|channelVolumes= +|channelVolumes=|g' "$rs"
    log "WP restore-stream: Music=${lin_soft} Chromium/FreeShow=${lin_fs} Movie=1.0"
}

# Apply FreeShow / Spotify levels even when already on Mixer
apply_software_levels() {
    local id bin app
    while read -r id; do
        [[ -z "$id" ]] && continue
        bin=$(sink_input_binary "$id" || true)
        app=$(pactl list sink-inputs 2>/dev/null | awk -v want="$id" '
            $1=="Sink" && $2=="Input" { cur=$3; gsub("#","",cur) }
            cur==want && /application\.name/ {
                line=$0; sub(/[^"]*"/, "", line); sub(/".*/, "", line); print line; exit
            }
        ')
        # Always skip ffplay/ffmpeg — genuinely always the program TV path
        # (LocalLive/HDMI), never Mixer.
        if [[ "${app,,}" == *ffplay* || "${bin,,}" == *ffplay* \
            || "${app,,}" == *ffmpeg* || "${bin,,}" == *ffmpeg* ]]; then
            continue
        fi
        # VLC is a genuinely mixed case: this policy predates FreeShow
        # embedding LibVLC for its own video/media playback, which shows up
        # identically to a standalone VLC process (same application.name,
        # "VLC media player (LibVLC ...)") — confirmed live 2026-09-04 that
        # FreeShow's media audio goes through exactly this identity, IS
        # already on Mixer (not LocalLive/HDMI), and was going completely
        # unmanaged because of this blanket skip — the actual cause of
        # "FreeShow's volume keeps coming back maxed." So: only skip a
        # VLC-named stream if it's NOT already on Mixer (i.e. a real
        # standalone/manual VLC session doing its own thing elsewhere,
        # which this script still must not touch); if it IS on Mixer,
        # that's FreeShow's embedded player and gets the same treatment as
        # the "Chromium"-identified FreeShow stream below.
        is_vlc_named=false
        [[ "${app,,}" == *vlc* || "${bin,,}" == *vlc* ]] && is_vlc_named=true
        if $is_vlc_named && [[ "$(sink_input_sink_id "$id" || true)" != "${SINK_ID:-}" ]]; then
            continue
        fi
        if [[ "$bin" == "freeshow" ]] || $is_vlc_named; then
            if $DRY_RUN; then
                log "DRY: FreeShow $id volume ${FREESHOW_VOLUME_PCT}%"
            else
                log "FreeShow stream $id volume → ${FREESHOW_VOLUME_PCT}%"
                pactl set-sink-input-mute "$id" 0 2>/dev/null || true
                pactl set-sink-input-volume "$id" "${FREESHOW_VOLUME_PCT}%" 2>/dev/null || true
            fi
        elif [[ "${app,,}" == *spotify* ]] || [[ "$bin" == "spotify" ]]; then
            if $DRY_RUN; then
                log "DRY: Spotify $id volume ${SOFTWARE_VOLUME_PCT}%"
            else
                log "Spotify stream $id volume → ${SOFTWARE_VOLUME_PCT}%"
                pactl set-sink-input-mute "$id" 0 2>/dev/null || true
                pactl set-sink-input-volume "$id" "${SOFTWARE_VOLUME_PCT}%" 2>/dev/null || true
            fi
        fi
    done < <(pactl list sink-inputs 2>/dev/null | awk '/^Sink Input #/ { gsub("#","",$3); print $3 }')
}

log "Ensuring software audio sources route to $TARGET_SINK (Presonus path)"
log "Levels: software=${SOFTWARE_VOLUME_PCT}% FreeShow=${FREESHOW_VOLUME_PCT}%"
fix_stream_restore_levels

SINK_ID=$(get_sink_id "$TARGET_SINK" || true)
if [[ -z "${SINK_ID}" ]]; then
    log "WARNING: Could not find sink containing '$TARGET_SINK'. Falling back to default behavior."
    # You could fall back to the raw Presonus name here.
fi

# Prefer Mixer as the session default so new apps land on the board path.
# (VLC is still free to use HDMI/other sinks; we do not move it below.)
if [[ -n "${SINK_ID}" ]]; then
    if $DRY_RUN; then
        log "DRY: pactl set-default-sink $TARGET_SINK"
    else
        if pactl set-default-sink "$TARGET_SINK" 2>/dev/null; then
            log "Default sink → $TARGET_SINK"
        else
            log "WARNING: could not set default sink to $TARGET_SINK"
        fi
    fi
fi

# Iterate over current sink inputs (Pulse/PipeWire view).
# END{} is required — last sink-input often has no trailing blank line (missed Spotify).
pactl list sink-inputs | awk '
    function flush() {
        if (id && app && !is_vlc) {
            print id "\t" app
        }
        id=""; app=""; is_vlc=0
    }
    /^Sink Input #/ {
        flush()
        id=$3; gsub("#","",id)
        next
    }
    /application\.name/ {
        line=$0
        sub(/^[^=]*=[ \t]*/, "", line)
        gsub(/"/, "", line)
        app=line
        next
    }
    /media\.name/ && app=="" {
        line=$0
        sub(/^[^=]*=[ \t]*/, "", line)
        gsub(/"/, "", line)
        app=line
        next
    }
    /application\.process\.binary/ && tolower($0) ~ /vlc/ { is_vlc=1 }
    /application\.name/ && tolower($0) ~ /vlc/ { is_vlc=1 }
    END { flush() }
' | while IFS=$'\t' read -r input_id app_name; do
    [[ -z "${input_id:-}" ]] && continue
    app_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')

    if echo "$app_lower" | grep -qiE 'vlc|ffplay|ffmpeg'; then
        log "Skipping program-TV stream (not Mixer): $app_name"
        continue
    fi

    # Move known software apps, and any stream still unattached (sink unset)
    is_software=false
    for pat in "${SOFTWARE_PATTERNS[@]}"; do
        if echo "$app_lower" | grep -qi "$pat"; then
            is_software=true
            break
        fi
    done
    # Always try Spotify node name / media role music (snap)
    if echo "$app_lower" | grep -qiE 'spotify|music'; then
        is_software=true
    fi

    if ! $is_software; then
        # Still move if currently not on a real sink (common PipeWire "unset" = 4294967295)
        sink_id=$(pactl list sink-inputs 2>/dev/null | awk -v want="$input_id" '
            $1=="Sink" && $2=="Input" { cur=$3; gsub("#","",cur) }
            cur==want && $1=="Sink:" { print $2; exit }
        ')
        if [[ "$sink_id" == "4294967295" || -z "$sink_id" ]]; then
            is_software=true
            log "Unattached stream (no sink): $app_name (input $input_id)"
        else
            log "Leaving non-software stream: $app_name"
            continue
        fi
    fi

    log "Found software source: $app_name (input $input_id)"
    if [[ -n "${SINK_ID}" ]]; then
        move_sink_input "$input_id" "$TARGET_SINK"
    else
        log "No target sink id; leaving for qpwgraph / default routing"
    fi
done

# FOH path (preferred once ALSA XRUN below is fixed): PipeWire Mixer → PreSonus
# pro-audio/multichannel AUX0/1. Full 64ch card stays in PipeWire for Ardour +
# qpwgraph. Force 64× unity channelVolumes via pw-cli ONLY (never pactl
# set-sink-volume/mute here — root-caused 2026-08-02: pactl goes through
# libpulse's PA_CHANNELS_MAX=32 protocol cap against this 64ch sink, and
# WirePlumber's restore-stream.lua persists+replays whatever-length array it
# last saw with zero channel-count validation. That 32-element replay onto a
# 64-channel node is what caused "volume stuck at 0%/-inf" — confirmed by
# clearing ~/.local/state/wireplumber/restore-stream's stale PreSonus
# playback entries + restarting wireplumber: AUX0/AUX1 came back to unity.
# Do not reintroduce a pactl volume/mute call on this sink.)
# Optional fallback: presonus-foh-bridge (ALSA exclusive — hides card from PW).
presonus_force_unity_volume() {
    local pres="$1"
    local nid vols
    [[ -n "$pres" ]] || return 0
    nid=$(pw-cli ls Node 2>/dev/null | awk -v n="$pres" '
        /id / { id=$2; gsub(",","",id) }
        $0 ~ "node.name = \"" n "\"" { print id; exit }
    ')
    if [[ -z "${nid:-}" ]]; then
        nid=$(pw-cli ls Node 2>/dev/null | awk '
            /id / { id=$2; gsub(",","",id) }
            /node.name = "alsa_output.usb-PreSonus/ { print id; exit }
        ')
    fi
    if [[ -n "${nid:-}" ]] && command -v pw-cli >/dev/null; then
        vols=$(python3 -c 'print("[" + ",".join(["1.0"]*64) + "]")')
        if pw-cli set-param "$nid" Props \
            "{ volume: 1.0, mute: false, channelVolumes: $vols, softVolumes: $vols }" \
            >/dev/null 2>&1; then
            log "PreSonus node $nid channelVolumes → 64×1.0 (pw-cli soft path)"
        else
            log "WARNING: pw-cli set-param volume failed on node ${nid:-?}"
        fi
    fi
}

if command -v pw-link >/dev/null; then
    log "Ensuring Mixer → Presonus FOH path (PipeWire multichannel)..."
    # FOH modes (2026-08-02):
    #   A) ALSA bridge (DEFAULT — still required today): card profile input-only
    #      or no PW playback sink; presonus-foh-bridge = parec Mixer.monitor|aplay.
    #      PW pro-audio *playback* had TWO stacked bugs found 2026-08-02:
    #        1. Volume stuck at 0%/-inf — root-caused + FIXED (WirePlumber
    #           restore-stream.lua replaying a stale 32-channel array onto the
    #           64-channel node; see presonus_force_unity_volume() comment above).
    #        2. ALSA hardware PCM enters XRUN immediately on open and never
    #           recovers (hw_ptr frozen just past one period in
    #           /proc/asound/cardN/pcm0p/sub0/status) — CONFIRMED, NOT YET FIXED.
    #           This is the actual reason native playback is still silent even
    #           with volume correct. Bridge remains the default FOH path until
    #           this is root-caused (suspect: USB isochronous bandwidth/timing
    #           for a 64ch/32-bit/48kHz stream, possibly contending with ATEM
    #           capture on the same USB controller).
    #   B) PW Mixer→AUX0/1 when a PreSonus *playback* sink exists (legacy/Ardour
    #      full duplex) — do not switch this to canonical/default until XRUN (2)
    #      above is fixed and confirmed audible end-to-end.
    CARD=$(pactl list short cards 2>/dev/null | awk '/PreSonus|StudioLive/{print $2; exit}')
    PRES=$(pactl list short sinks 2>/dev/null | awk '/PreSonus|StudioLive/ && /output|pro-output/{print $2; exit}')
    BRIDGE_ON=false
    if systemctl --user is-active --quiet presonus-foh-bridge.service 2>/dev/null \
        || { pgrep -x aplay >/dev/null 2>&1 && pgrep -x parec >/dev/null 2>&1; }; then
        BRIDGE_ON=true
    fi

    if $BRIDGE_ON; then
        log "FOH: ALSA bridge active (Mixer.monitor → aplay presonus_foh → USB 1–2)"
        # Keep capture available; do not force pro-audio playback (steals device from bridge)
        if [[ -n "${CARD:-}" ]] && ! $DRY_RUN; then
            # Prefer input-only so PW does not open broken playback
            cur=$(pactl list cards 2>/dev/null | awk -v c="$CARD" '
                $0 ~ "Name: "c {p=1} p&&/Active Profile:/{print $3; exit}')
            if [[ "$cur" == *output* || "$cur" == "pro-audio" ]]; then
                log "Card profile $cur conflicts with bridge — switching to input:multichannel-input"
                pactl set-card-profile "$CARD" input:multichannel-input 2>/dev/null || true
            fi
        fi
    elif [[ -n "${PRES:-}" ]]; then
        log "FOH: PipeWire PreSonus sink $PRES (Mixer→AUX0/1)"
        if ! $DRY_RUN; then
            presonus_force_unity_volume "$PRES"
        fi
        PRES_L=""
        PRES_R=""
        if pw-link -i 2>/dev/null | grep -q "^${PRES}:playback_AUX0$"; then
            PRES_L="${PRES}:playback_AUX0"
            PRES_R="${PRES}:playback_AUX1"
        elif pw-link -i 2>/dev/null | grep -q "^${PRES}:playback_FL$"; then
            PRES_L="${PRES}:playback_FL"
            PRES_R="${PRES}:playback_FR"
        elif pw-link -i 2>/dev/null | grep -q "^${PRES}:playback_1$"; then
            PRES_L="${PRES}:playback_1"
            PRES_R="${PRES}:playback_2"
        fi
        if [[ -n "${PRES_L}" ]]; then
            if $DRY_RUN; then
                log "DRY: pw-link Mixer:monitor_* → ${PRES_L} / ${PRES_R}"
            else
                log "Linking Mixer → ${PRES_L} / ${PRES_R}"
                pw-link Mixer:monitor_FL "${PRES_L}" 2>/dev/null || true
                pw-link Mixer:monitor_FR "${PRES_R}" 2>/dev/null || true
            fi
        else
            log "WARNING: PreSonus ports not found on ${PRES}"
        fi
    else
        log "WARNING: no FOH path — start: systemctl --user start presonus-foh-bridge"
        if [[ -n "${CARD:-}" ]] && ! $DRY_RUN; then
            pactl set-card-profile "$CARD" input:multichannel-input 2>/dev/null || true
            systemctl --user start presonus-foh-bridge.service 2>/dev/null || true
        fi
    fi
    # Spotify snap ports
    if pw-link -o 2>/dev/null | grep -q '^spotify:output_FL$'; then
        if $DRY_RUN; then
            log "DRY: pw-link spotify → Mixer"
        else
            pw-link spotify:output_FL Mixer:playback_FL 2>/dev/null || true
            pw-link spotify:output_FR Mixer:playback_FR 2>/dev/null || true
        fi
    fi
fi

apply_software_levels

# Program TV audio: ffplay → HDMI TV stereo sink (not Mixer/FOH)
if ! $DRY_RUN; then
    # Prefer stereo profile for HDMI TV so Pulse can attach streams
    pactl set-card-profile alsa_card.pci-0000_07_00.1 output:hdmi-stereo-extra1 2>/dev/null || true
    TV_SINK=$(pactl list short sinks 2>/dev/null | awk '/hdmi-stereo-extra1/ {print $2; exit}')
    [[ -n "$TV_SINK" ]] || TV_SINK=$(pactl list short sinks 2>/dev/null | awk '/hdmi-stereo/ {print $2; exit}')
    if [[ -n "${TV_SINK:-}" ]]; then
        while read -r id; do
            [[ -z "$id" ]] && continue
            bin=$(sink_input_binary "$id" || true)
            if [[ "$bin" == "ffplay" ]]; then
                log "Moving ffplay input $id → ${TV_SINK} (HDMI TV)"
                pactl move-sink-input "$id" "$TV_SINK" 2>/dev/null || true
                pactl set-sink-input-mute "$id" 0 2>/dev/null || true
            fi
        done < <(pactl list sink-inputs 2>/dev/null | awk '/^Sink Input #/ { gsub("#","",$3); print $3 }')
    fi
fi

log "Done. Current relevant links:"
pw-link -l 2>/dev/null | grep -iE 'mixer|presonus|spotify|chromium|vivaldi|firefox|freeshow|ffplay|LocalLive' | head -40 || true

if $DRY_RUN; then
    echo "=== END DRY RUN ==="
fi
