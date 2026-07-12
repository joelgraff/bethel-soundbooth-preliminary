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

SOFTWARE_PATTERNS=(
    "spotify"
    "chromium"
    "vivaldi"
    "firefox"
    "free show"
    "freeshow"
    # add more as needed
)

VLC_PATTERN="vlc"   # We deliberately leave VLC alone

get_sink_id() {
    pactl list short sinks | awk -v name="$1" 'index($2, name) {print $1; exit}'
}

move_sink_input() {
    local input_id="$1"
    local sink_name="$2"
    if $DRY_RUN; then
        log "DRY: pactl move-sink-input $input_id $sink_name"
    else
        log "Moving sink-input $input_id → $sink_name"
        pactl move-sink-input "$input_id" "$sink_name" || true
    fi
}

log "Ensuring software audio sources route to $TARGET_SINK (Presonus path)"

SINK_ID=$(get_sink_id "$TARGET_SINK" || true)
if [[ -z "${SINK_ID}" ]]; then
    log "WARNING: Could not find sink containing '$TARGET_SINK'. Falling back to default behavior."
    # You could fall back to the raw Presonus name here.
fi

# Iterate over current sink inputs (Pulse/PipeWire view)
pactl list sink-inputs | awk '
    /^Sink Input #/ { id=$3; gsub("#","",id); app=""; }
    /application.name/ { $1=""; $2=""; app=$0; gsub(/^[ \t]+|"/,"",app); }
    /media.name/ && app=="" { $1=""; $2=""; app=$0; gsub(/^[ \t]+|"/,"",app); }
    /VLC|vlc/ { is_vlc=1 }
    /^$/ {
        if (id && app && !is_vlc) {
            print id " | " app
        }
        id=""; app=""; is_vlc=0;
    }
' | while IFS=' | ' read -r input_id app_name; do
    app_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')

    skip=false
    if echo "$app_lower" | grep -qi "$VLC_PATTERN"; then
        skip=true
    fi

    for pat in "${SOFTWARE_PATTERNS[@]}"; do
        if echo "$app_lower" | grep -qi "$pat"; then
            skip=false
            break
        fi
    done

    if $skip; then
        log "Skipping (VLC or unmatched): $app_name"
        continue
    fi

    log "Found software source: $app_name (input $input_id)"
    if [[ -n "${SINK_ID}" ]]; then
        move_sink_input "$input_id" "$TARGET_SINK"
    else
        log "No target sink id; leaving for qpwgraph / default routing"
    fi
done

# Also try raw pw-link for nodes that don't appear as sink-inputs
# (some apps show up only in the PipeWire graph)
if command -v pw-link >/dev/null; then
    log "Checking raw PipeWire nodes for additional software sources..."
    # This is intentionally lightweight; the WP rule should do most of the work.
    # You can extend with specific pw-link commands here if needed.
fi

log "Done. Current relevant links:"
pw-link -l 2>/dev/null | grep -iE 'mixer|presonus|spotify|chromium|vivaldi|firefox' | head -20 || true

if $DRY_RUN; then
    echo "=== END DRY RUN ==="
fi
