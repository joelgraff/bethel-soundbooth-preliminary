#!/bin/bash
# Regression test for av-sync-calibrate.py's offline "synthetic" mode.
#
# Captures the one-off manual validation from STATUS.md (2026-08-02):
# "Synthetic mode: measured a known injected 250ms delay to within 15ms,
# zero variance across all pairs — detector + production filter logic
# confirmed sound." That was checked by hand once and never re-run; a future
# edit to the flash/beep detector, the production adelay filter chain, or the
# pairing/median logic could silently break measurement accuracy with
# nothing to catch it. This makes that check repeatable.
#
# Fully offline: synthetic mode generates its own lavfi flash+beep source and
# encodes it with the same filter chain as production, so this needs only
# ffmpeg + python3 — no ATEM/hardware, safe to run anytime.
#
# Usage:
#   ./av-sync-calibrate-test.sh
#
# Exit: 0 = all injected delays measured within tolerance, 1 = a case failed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAL="${HOME}/bin/av-sync-calibrate.py"
[[ -f "$CAL" ]] || CAL="${HERE}/../scripts/av-sync-calibrate.py"
if [[ ! -f "$CAL" ]]; then
    echo "FAIL: av-sync-calibrate.py not found" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL: python3 not available" >&2
    exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "FAIL: ffmpeg not available (required by av-sync-calibrate)" >&2
    exit 1
fi

# Delays to inject and verify (seconds): 0.25 is the STATUS.md 2026-08-02
# case; 0.0 is a second independent data point (no adelay in the chain).
DELAYS=(0.25 0.0)
DURATION=6
OVERALL_FAIL=0

for d in "${DELAYS[@]}"; do
    echo "--- synthetic delay=${d}s ---"
    out=$(python3 "$CAL" synthetic --delay "$d" --duration "$DURATION" --json 2>&1)
    rc=$?

    # main()'s leading progress prints land on stdout even with --json; find
    # the JSON object rather than assuming stdout is pure JSON.
    read -r verdict err_ms pair_count <<<"$(echo "$out" | python3 -c '
import json, sys
s = sys.stdin.read()
i = s.find("{")
try:
    d = json.loads(s[i:]) if i >= 0 else {}
except Exception:
    d = {}
interp = d.get("interpret", {})
measure = d.get("measure", {})
print(interp.get("verdict", "PARSE_ERROR"),
      interp.get("synthetic_error_ms", "n/a"),
      measure.get("pair_count", "n/a"))
')"

    if [[ "$rc" -eq 0 && "$verdict" == "synthetic_ok" ]]; then
        echo "  PASS: verdict=synthetic_ok error=${err_ms}ms pairs=${pair_count}"
    else
        echo "  FAIL: exit=${rc} verdict=${verdict} error=${err_ms}ms pairs=${pair_count}"
        echo "$out" | tail -25
        OVERALL_FAIL=1
    fi
done

echo
if [[ "$OVERALL_FAIL" -eq 0 ]]; then
    echo "av-sync-calibrate-test: OK — detector + production adelay filter confirmed sound"
    exit 0
else
    echo "av-sync-calibrate-test: FAIL — see above (detector or filter chain may have regressed)" >&2
    exit 1
fi
