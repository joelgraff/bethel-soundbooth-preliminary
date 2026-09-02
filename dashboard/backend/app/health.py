"""Wraps `soundbooth-health.sh --json` (the flag already exists in that
script — audio-routing/scripts/soundbooth-health.sh — no changes needed
there).
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path


class HealthCheckError(RuntimeError):
    pass


def get_health_status(health_script: Path, timeout: int = 30) -> dict:
    if not health_script.is_file():
        raise HealthCheckError(f"health script not found: {health_script}")
    try:
        proc = subprocess.run(
            [str(health_script), "--json"],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise HealthCheckError("soundbooth-health.sh --json timed out") from exc

    # Exit code is 0/1/2 for fail/warn/pass counts (see the script), not an
    # error signal — only a missing/unparsable payload is a real failure here.
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise HealthCheckError(
            f"could not parse health output: {proc.stdout[:200]!r}"
        ) from exc
    return payload
