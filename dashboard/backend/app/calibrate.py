"""Orchestrates av-sync-calibrate.py's `capture-udp` mode from the
dashboard, so it and the DP-4 preview capture never actually fight over the
shared :5002 UDP tee (unicast, one reader) — this is the "roll the
calibration tool into the dashboard" answer to that conflict: the dashboard
owns both consumers of :5002, so it can just take turns instead of either
racing or accepting a broken preview during every calibration.

See audio-routing/scripts/start-hdmi-preview-dp4.sh and
audio-routing/scripts/av-sync-calibrate.py.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

from . import systemctl_client

DP4_PREVIEW_UNIT = "hdmi-preview-dp4.service"
DEFAULT_DURATION = 12.0
MIN_DURATION = 6.0
MAX_DURATION = 30.0


class CalibrationError(RuntimeError):
    pass


def _extract_json(stdout: str) -> dict:
    """`av-sync-calibrate.py --json` still prints a couple of plain-text
    progress lines before the JSON dump (that output isn't gated by --json,
    only the final report is) — find where the multi-line
    `json.dumps(..., indent=2)` block starts and parse from there rather
    than assuming stdout is pure JSON."""
    lines = stdout.splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "{":
            candidate = "\n".join(lines[i:])
            try:
                return json.loads(candidate)
            except json.JSONDecodeError:
                continue
    raise CalibrationError(f"could not find JSON output in: {stdout[-500:]!r}")


def run_calibration(*, script_path: Path, duration: float = DEFAULT_DURATION) -> dict:
    duration = max(MIN_DURATION, min(float(duration), MAX_DURATION))
    if not script_path.is_file():
        raise CalibrationError(f"calibration script not found: {script_path}")

    # Best-effort: if the preview service isn't installed/running there's
    # nothing to conflict with, and that shouldn't block calibration itself.
    try:
        systemctl_client.run_action(DP4_PREVIEW_UNIT, "stop")
    except systemctl_client.SystemctlError:
        pass

    try:
        proc = subprocess.run(
            [str(script_path), "capture-udp", "--json", "--duration", str(duration)],
            capture_output=True,
            text=True,
            timeout=duration + 30,
        )
    except subprocess.TimeoutExpired as exc:
        raise CalibrationError("calibration timed out") from exc
    finally:
        # Always try to resume the preview, whether calibration succeeded,
        # measured an out-of-sync result, or failed outright.
        try:
            systemctl_client.run_action(DP4_PREVIEW_UNIT, "start")
        except systemctl_client.SystemctlError:
            pass

    if proc.returncode not in (0, 2):
        # 0 = in sync, 2 = measured but out of tolerance — both are real
        # results, not errors. Anything else means the capture itself failed
        # (e.g. no cal pattern on program) — see av-sync-calibrate.py's
        # sys.exit() calls in capture_udp().
        raise CalibrationError(
            (proc.stderr or proc.stdout or "calibration failed").strip()[-500:]
        )

    return _extract_json(proc.stdout)
