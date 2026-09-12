#!/bin/bash
# Non-interactive smoke test for soundbooth-health.sh
# Exit: 0 = health ok, 1 = health reported warn, 2 = health reported fail,
#       3 = health script missing/broken
#
# Usage:
#   ./smoke-health.sh
#   ./smoke-health.sh --strict    # treat warn as failure (exit 1)
#
# CI / post-change: expect exit 0 on a healthy booth boot.

set -uo pipefail

STRICT=false
[[ "${1:-}" == "--strict" ]] && STRICT=true

HEALTH="${HOME}/bin/soundbooth-health.sh"
if [[ ! -x "$HEALTH" ]]; then
    # fall back to project copy
    HEALTH="${HOME}/soundbooth-project/audio-routing/scripts/soundbooth-health.sh"
fi
if [[ ! -f "$HEALTH" ]]; then
    echo "FAIL: soundbooth-health.sh not found" >&2
    exit 3
fi

# Display cookie for headless/Grok sessions (same as health itself)
export DISPLAY="${DISPLAY:-:0}"
if [[ -z "${XAUTHORITY:-}" || ! -f "${XAUTHORITY:-}" ]]; then
    if [[ -f "${HOME}/bin/vlc-display-lib.sh" ]]; then
        # shellcheck disable=SC1091
        source "${HOME}/bin/vlc-display-lib.sh"
        soundbooth_export_display_env || true
    fi
fi

out=$("$HEALTH" --quiet 2>&1) || rc=$?
rc=${rc:-0}
echo "$out"

case "$rc" in
    0)
        echo "smoke-health: OK (exit 0)"
        exit 0
        ;;
    1)
        if $STRICT; then
            echo "smoke-health: STRICT fail on WARN (exit 1)" >&2
            exit 1
        fi
        echo "smoke-health: WARN (exit 1) — review full report: ~/bin/soundbooth-health.sh"
        exit 1
        ;;
    2)
        echo "smoke-health: FAIL (exit 2) — fix before service" >&2
        exit 2
        ;;
    *)
        echo "smoke-health: unexpected exit $rc" >&2
        exit 3
        ;;
esac
