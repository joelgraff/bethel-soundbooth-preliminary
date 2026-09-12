#!/bin/bash
# backup-configs.sh — snapshot soundbooth config into a dated archive
#
# Usage (from anywhere):
#   ~/soundbooth-project/replicability/provision/backup-configs.sh
#   BACKUP_DIR=/path/to/backups ./backup-configs.sh
#
# Captures scripts, PipeWire/WirePlumber, systemd user units, patchbay,
# project tree (excluding large media), and key docs — not full home/media.

set -euo pipefail

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
HOST=$(hostname -s 2>/dev/null || echo soundbooth)
BACKUP_DIR="${BACKUP_DIR:-$HOME/soundbooth-project/replicability/backups}"
ARCHIVE="${BACKUP_DIR}/soundbooth-config-${HOST}-${STAMP}.tar.gz"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$BACKUP_DIR"
mkdir -p "$STAGING/home" "$STAGING/meta"

log() { echo "[backup] $*"; }

# Manifest of what we intend to back up (paths relative to $HOME unless absolute)
PATHS=(
    "bin"
    "soundbooth-project"
    "patchbay_profile"
    "booth_ai"
    ".config/wireplumber"
    ".config/pipewire"
    ".config/systemd/user"
    ".config/qpwgraph"
    ".local/share/applications"
)

log "Staging from HOME=$HOME"
for rel in "${PATHS[@]}"; do
    src="$HOME/$rel"
    if [[ -e "$src" ]]; then
        log "  + $rel"
        mkdir -p "$STAGING/home/$(dirname "$rel")"
        # Copy; skip heavy caches if any under these trees
        rsync -a --exclude='.git/objects' --exclude='node_modules' \
            --exclude='backups/*.tar.gz' \
            "$src" "$STAGING/home/$(dirname "$rel")/" 2>/dev/null \
            || cp -a "$src" "$STAGING/home/$(dirname "$rel")/"
    else
        log "  - (missing) $rel"
    fi
done

# Metadata for restore
{
    echo "created_utc=$STAMP"
    echo "hostname=$HOST"
    echo "user=$USER"
    echo "home=$HOME"
    uname -a
    echo "---"
    pactl info 2>/dev/null | head -20 || true
    echo "---"
    systemctl --user list-unit-files 2>/dev/null | egrep -i 'qpwgraph|vlc|ardour|virtual|soundbooth' || true
} > "$STAGING/meta/backup-info.txt"

# File list
( cd "$STAGING" && find . -type f | sort ) > "$STAGING/meta/file-list.txt"

log "Creating $ARCHIVE"
tar -C "$STAGING" -czf "$ARCHIVE" .
# Side-car checksum
( cd "$BACKUP_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )

log "OK: $ARCHIVE"
ls -lh "$ARCHIVE"
echo "$ARCHIVE"
