"""Livestream auto-start schedule — read and change livestream-autostart.timer.

The Subsplash relay (ffmpeg-srt-relay.service) is deliberately NOT started at
boot; see SYSTEM-STATE.md. This timer is the only *automatic* start path, so a
disarmed timer means the Sunday stream silently never starts — which is exactly
why it's worth surfacing on the dashboard rather than leaving it CLI-only.

Split of responsibility, on purpose:
  * READS go straight to `systemctl --user show -p` — structured, cheap, and no
    output parsing of a human-facing script.
  * WRITES go through ~/bin/livestream-schedule.sh, which already validates the
    calendar spec and knows the OnCalendar-reset gotcha (systemd *accumulates*
    OnCalendar across a unit and its drop-ins, so a drop-in must emit a bare
    `OnCalendar=` before the new value or the old time keeps firing too).
    Reimplementing that here would mean two copies of a subtle rule.

This is NOT routed through units.py/units_manifest.json: that path models
start/stop/restart on a service, and "set a recurring time" / "arm the schedule"
aren't those verbs. Like recording.py and calibrate.py, this talks to its own
tool directly. Consequently ConfirmStore (which keys on unit+action) doesn't
apply either — the frontend confirms disarming with its own modal, since that's
the action that can quietly cost a Sunday.
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

TIMER_UNIT = "livestream-autostart.timer"
RELAY_UNIT = "ffmpeg-srt-relay.service"

# Belt-and-braces only: the spec is always passed as a single argv element (never
# shell=True) and `systemd-analyze calendar` is the real gate — verified to reject
# newline, ";", backtick and "$(...)" payloads. But the value ends up inside a
# systemd drop-in file, so refuse anything that isn't plausibly a calendar spec
# before it gets near there. systemd calendar syntax needs only these characters.
_SPEC_RE = re.compile(r"^[A-Za-z0-9 ,:*/~+.-]{1,200}$")


class ScheduleError(RuntimeError):
    pass


def _run(argv: list[str], timeout: int = 20) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout, check=False
        )
    except FileNotFoundError as exc:
        raise ScheduleError(f"command not found: {argv[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise ScheduleError(f"timed out: {' '.join(argv)}") from exc


def _show(unit: str, *props: str) -> dict[str, str]:
    proc = _run(["systemctl", "--user", "show", unit, f"--property={','.join(props)}"])
    out: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            out[k] = v
    return out


def _calendar_specs(timers_calendar: str) -> list[str]:
    """Pull the specs out of TimersCalendar.

    Formatted as "{ OnCalendar=Sun *-*-* 09:23:00 ; next_elapse=... }", one group
    per entry, so the raw value is not directly presentable.
    """
    return [m.strip() for m in re.findall(r"OnCalendar=([^;}]*)", timers_calendar)]


def get_schedule() -> dict:
    """Current schedule state. Never raises for 'not installed' — reports it."""
    timer = _show(
        TIMER_UNIT,
        "LoadState",
        "UnitFileState",
        "ActiveState",
        "TimersCalendar",
        "NextElapseUSecRealtime",
        "LastTriggerUSec",
    )
    relay = _show(RELAY_UNIT, "ActiveState", "UnitFileState")

    installed = timer.get("LoadState") == "loaded"
    specs = _calendar_specs(timer.get("TimersCalendar", ""))
    # On this systemd, NextElapseUSecRealtime --property renders as a local-time
    # string already, not microseconds — pass it through rather than converting.
    next_run = timer.get("NextElapseUSecRealtime", "") or ""
    last_run = timer.get("LastTriggerUSec", "") or ""

    return {
        "installed": installed,
        "armed": timer.get("UnitFileState") == "enabled"
        and timer.get("ActiveState") == "active",
        "unit_file_state": timer.get("UnitFileState", "unknown"),
        "active_state": timer.get("ActiveState", "unknown"),
        "schedule": specs,
        "schedule_text": "; ".join(specs),
        "next_run": next_run if next_run not in ("0", "n/a") else "",
        "last_run": last_run if last_run not in ("0", "n/a") else "",
        "stream_active": relay.get("ActiveState") == "active",
        # Surfaced so the UI can warn: 'enabled' here means the relay would start
        # at every boot, which is the regression this whole arrangement removed.
        "relay_boot_enabled": relay.get("UnitFileState") == "enabled",
    }


def validate_spec(spec: str) -> str:
    spec = (spec or "").strip()
    if not spec:
        raise ScheduleError("schedule cannot be empty")
    if not _SPEC_RE.match(spec):
        raise ScheduleError(
            "schedule contains characters that aren't valid in a calendar spec"
        )
    proc = _run(["systemd-analyze", "calendar", spec], timeout=10)
    if proc.returncode != 0:
        raise ScheduleError(
            f"'{spec}' is not a valid schedule. Try a form like 'Sun 09:23' "
            "or 'Sun,Wed 18:30'."
        )
    return spec


def _script(script: Path) -> Path:
    if not script.is_file():
        raise ScheduleError(f"schedule tool not found: {script}")
    return script


def set_schedule(*, spec: str, script: Path) -> dict:
    """Set the recurring day/time. Validated here so the API can 400 cleanly."""
    spec = validate_spec(spec)
    proc = _run([str(_script(script)), "--set", spec], timeout=30)
    if proc.returncode != 0:
        raise ScheduleError(
            f"failed to set schedule: {(proc.stderr or proc.stdout).strip()}"
        )
    return get_schedule()


def set_armed(*, armed: bool, script: Path) -> dict:
    flag = "--enable" if armed else "--disable"
    proc = _run([str(_script(script)), flag], timeout=30)
    if proc.returncode != 0:
        raise ScheduleError(
            f"failed to {flag.lstrip('-')} schedule: "
            f"{(proc.stderr or proc.stdout).strip()}"
        )
    return get_schedule()
