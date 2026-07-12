#!/bin/bash
# restore-configs.sh — restore a soundbooth-config-*.tar.gz backup
#
# Usage:
#   ./restore-configs.sh /path/to/soundbooth-config-HOST-STAMP.tar.gz
#   ./restore-configs.sh --dry-run /path/to/archive.tar.gz
#
# Restores into $HOME. Existing files are overwritten. Creates a
# pre-restore safety snapshot of overlapping paths when possible.

set -euo pipefail

DRY_RUN=false
ARCHIVE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *) ARCHIVE="$1"; shift ;;
    esac
done

if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
    echo "Usage: $0 [--dry-run] <soundbooth-config-*.tar.gz>" >&2
    exit 1
fi

log() { echo "[restore] $*"; }

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

log "Extracting archive listing..."
tar -tzf "$ARCHIVE" | head -50
echo "..."

if $DRY_RUN; then
    log "DRY RUN — would restore home/* from archive into $HOME"
    tar -tzf "$ARCHIVE" | grep '^\./home/' | head -100
    exit 0
fi

# Optional checksum verify
if [[ -f "${ARCHIVE}.sha256" ]]; then
    log "Verifying checksum..."
    ( cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256" )
fi

log "Extracting to staging..."
tar -C "$STAGING" -xzf "$ARCHIVE"

if [[ ! -d "$STAGING/home" ]]; then
    echo "Error: archive has no home/ tree" >&2
    exit 1
fi

# Safety snapshot of targets that will be overwritten
SAFETY_DIR="${HOME}/soundbooth-project/replicability/backups/pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$SAFETY_DIR"
log "Safety copies → $SAFETY_DIR"
for d in bin soundbooth-project patchbay_profile .config/wireplumber .config/pipewire .config/systemd/user; do
    if [[ -e "$HOME/$d" ]]; then
        mkdir -p "$SAFETY_DIR/$(dirname "$d")"
        rsync -a "$HOME/$d" "$SAFETY_DIR/$(dirname "$d")/" 2>/dev/null || true
    fi
done

log "Restoring into $HOME ..."
rsync -a "$STAGING/home/" "$HOME/"

if [[ -f "$STAGING/meta/backup-info.txt" ]]; then
    log "Backup metadata:"
    cat "$STAGING/meta/backup-info.txt"
fi

log "Reloading user systemd (if available)..."
systemctl --user daemon-reload 2>/dev/null || true

log "Done. Review audio:"
log "  systemctl --user restart wireplumber"
log "  ~/bin/ensure-audio-routes.sh"
log "Safety snapshot kept at: $SAFETY_DIR"
