"""Thin, safe wrapper around `systemctl --user` / `journalctl --user`.

Every call here takes a unit name that the caller must have already checked
against units.check_action_allowed() — this module does not itself consult
the manifest, on purpose, so it stays a dumb, auditable last mile. Always
invoked as an argv list (never shell=True) so a unit name can't inject shell
syntax even if validation upstream were ever buggy.
"""
from __future__ import annotations

import subprocess


class SystemctlError(RuntimeError):
    pass


def _run(argv: list[str], timeout: int = 15) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout, check=False
        )
    except FileNotFoundError as exc:
        raise SystemctlError(f"command not found: {argv[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise SystemctlError(f"timed out: {' '.join(argv)}") from exc


def get_status(unit: str) -> dict:
    proc = _run(
        [
            "systemctl",
            "--user",
            "show",
            unit,
            "--property=ActiveState,SubState,Result",
        ]
    )
    props: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            props[k] = v
    return {
        "active_state": props.get("ActiveState", "unknown"),
        "sub_state": props.get("SubState", "unknown"),
        "result": props.get("Result", "unknown"),
    }


def run_action(unit: str, action: str) -> None:
    """action must already be validated (restart|start|stop) by the caller."""
    proc = _run(["systemctl", "--user", action, unit], timeout=30)
    if proc.returncode != 0:
        raise SystemctlError(
            f"systemctl --user {action} {unit} failed: {proc.stderr.strip()}"
        )


def tail_journal(unit: str, lines: int = 50) -> list[str]:
    lines = max(1, min(int(lines), 200))
    proc = _run(
        [
            "journalctl",
            "--user",
            "-u",
            unit,
            "-n",
            str(lines),
            "--no-pager",
            "-o",
            "short-iso",
        ],
        timeout=15,
    )
    if proc.returncode != 0:
        raise SystemctlError(f"journalctl for {unit} failed: {proc.stderr.strip()}")
    return proc.stdout.splitlines()
