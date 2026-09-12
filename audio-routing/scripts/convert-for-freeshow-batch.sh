#!/bin/bash
# convert-for-freeshow-batch.sh
# Convert all webm/mkv/etc under a directory to FreeShow-friendly H.264 MP4.
#
# Usage:
#   convert-for-freeshow-batch.sh                  # default: ~/Downloads
#   convert-for-freeshow-batch.sh /path/to/media
#   convert-for-freeshow-batch.sh --force /path    # re-encode even if .mp4 exists
#
# Skips files that already have a sibling .mp4 (unless --force).

set -euo pipefail

FORCE=false
ROOT="${HOME}/Downloads"
CONV="${HOME}/bin/convert-for-freeshow.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-f) FORCE=true; shift ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *) ROOT="$1"; shift ;;
    esac
done

if [[ ! -d "$ROOT" ]]; then
    echo "Error: directory not found: $ROOT" >&2
    exit 1
fi
if [[ ! -x "$CONV" ]]; then
    echo "Error: converter missing or not executable: $CONV" >&2
    exit 1
fi

# Extensions that commonly need re-encode for this GPU (no VP9 HW decode)
mapfile -d '' FILES < <(find "$ROOT" -type f \( \
    -iname '*.webm' -o -iname '*.mkv' -o -iname '*.vp9' \
    \) -print0 2>/dev/null)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "No convertible video files under: $ROOT"
    exit 0
fi

ok=0
skip=0
fail=0

echo "Batch convert under: $ROOT"
echo "Found ${#FILES[@]} candidate(s). Force=$FORCE"
echo

for input in "${FILES[@]}"; do
    [[ -z "$input" ]] && continue
    out="${input%.*}.mp4"
    if [[ -f "$out" && "$FORCE" != true ]]; then
        echo "SKIP  (mp4 exists): $input"
        skip=$((skip + 1))
        continue
    fi
    echo "==== CONVERT ===="
    if "$CONV" "$input" "$out"; then
        ok=$((ok + 1))
    else
        echo "FAILED: $input" >&2
        fail=$((fail + 1))
    fi
    echo
done

echo "Done. converted=$ok skipped=$skip failed=$fail"
[[ "$fail" -eq 0 ]]
